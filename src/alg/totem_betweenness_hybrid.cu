/**
 * This file contains a hybrid implementation of the Betweenness Centrality
 * algorithm using the Totem framework
 *
 *  Created on: 2013-03-10
 *  Author: Abdullah Gharaibeh
 *          Robert Woff
 */

// Totem includes
#include "totem_alg.h"
#include "totem_centrality.h"
#include "totem_engine.cuh"

/**
 * Per-partition specific state
 */
typedef struct betweenness_state_s {
  cost_t*   distance[MAX_PARTITION_COUNT]; // a list of distances state, one per
                                           // partition
  uint32_t* numSPs[MAX_PARTITION_COUNT]; // a list of number of shortest paths
                                           // state, one per partition
  uint32_t* numSPs_f[MAX_PARTITION_COUNT]; // a list of number of shortest paths
                                           // state, one per partition
  score_t*  delta[MAX_PARTITION_COUNT];    // delta BC score for a vertex
  bool*     done;        // pointer to global finish flag
  cost_t    level;       // current level being processed by the partition
  score_t*  betweenness; // betweenness score

  vid_t* frontier_list;  // maintains the list of vertices the belong to the
                         // current frontier being processed (GPU-based 
                         // partitions only)
  vid_t* frontier_count; // number of vertices in the frontier (GPU-based
                         // partitions only)
} betweenness_state_t;

/**
 * State shared between all partitions
 */
typedef struct betweenness_global_state_s {
  score_t*   betweenness_score;   // final output buffer
  score_t*   betweenness_score_h; // used as a temporary buffer
  vid_t      src;                 // source vertex id (id after partitioning)
  double     epsilon;             // determines accuracy of BC computation
  int        num_samples;         // number of samples for approximate BC
} betweenness_global_state_t;
PRIVATE betweenness_global_state_t bc_g;

/**
 * The neighbors forward propagation processing function. This function sets 
 * the level of the neighbors' vertex to one level more than the parent vertex.
 * The assumption is that the threads of a warp invoke this function to process
 * the warp's batch of work. In each iteration of the for loop, each thread 
 * processes a neighbor. For example, thread 0 in the warp processes neighbors 
 * at indices 0, VWARP_WIDTH, (2 * VWARP_WIDTH) etc. in the edges array, while
 * thread 1 in the warp processes neighbors 1, (1 + VWARP_WIDTH), 
 * (1 + 2 * VWARP_WIDTH) and so on.
 */
template<int VWARP_WIDTH>
__device__ inline void
forward_process_neighbors(int warp_offset, const vid_t* __restrict nbrs, 
                          const vid_t nbr_count, uint32_t v_numSPs, 
                          betweenness_state_t* state, bool& done_d) {
  // Iterate through the portion of work
  for(vid_t i = warp_offset; i < nbr_count; i += VWARP_WIDTH) {
    vid_t nbr = GET_VERTEX_ID(nbrs[i]);
    int nbr_pid = GET_PARTITION_ID(nbrs[i]);
    cost_t* nbr_distance = state->distance[nbr_pid];
    if (nbr_distance[nbr] == INF_COST) {
      nbr_distance[nbr] = state->level + 1;
      done_d = false;
    }
    if (nbr_distance[nbr] == state->level + 1) {
      uint32_t* numSPs = state->numSPs_f[nbr_pid];
      atomicAdd(&(numSPs[nbr]), v_numSPs);
    }
  }
}

template<int VWARP_WIDTH, int VWARP_BATCH>
__global__ void
betweenness_gpu_forward_kernel(partition_t par, betweenness_state_t state) {
  vid_t frontier_count = *state.frontier_count;
  if (THREAD_GLOBAL_INDEX >= 
      vwarp_thread_count(frontier_count, VWARP_WIDTH, VWARP_BATCH)) return;

  const vid_t* __restrict frontier = state.frontier_list;
  const eid_t* __restrict vertices = par.subgraph.vertices;
  const vid_t* __restrict edges = par.subgraph.edges;
  const uint32_t* __restrict numSPs = state.numSPs[par.id];

  // This flag is used to report the finish state of a block of threads. This
  // is useful to avoid having many threads writing to the global finished
  // flag, which can hurt performance (since "finished" is actually allocated
  // on the host, and each write will cause a transfer over the PCI-E bus)
  __shared__ bool finished_block;
  finished_block = true;
  __syncthreads();

  vid_t start_vertex = vwarp_block_start_vertex(VWARP_WIDTH, VWARP_BATCH) + 
    vwarp_warp_start_vertex(VWARP_WIDTH, VWARP_BATCH);
  vid_t end_vertex = start_vertex +
    vwarp_warp_batch_size(frontier_count, VWARP_WIDTH, VWARP_BATCH);
  int warp_offset = vwarp_thread_index(VWARP_WIDTH);
  
  // Iterate over my work
  for(vid_t i = start_vertex; i < end_vertex; i++) {
    vid_t v = frontier[i];
    // If the distance for this node is equal to the current level, then
    // forward process its neighbours to determine its contribution to
    // the number of shortest paths
    const eid_t nbr_count = vertices[v + 1] - vertices[v];
    const vid_t* __restrict nbrs = &(edges[vertices[v]]);
    forward_process_neighbors<VWARP_WIDTH>
      (warp_offset, nbrs, nbr_count, numSPs[v], &state, finished_block);    
  }

  __syncthreads();
  // If there is remaining work to do, set the done flag to false
  if (!finished_block && THREAD_BLOCK_INDEX == 0) *(state.done) = false;
}

__global__ void
build_frontier_kernel(const vid_t vertex_count, const cost_t level,
                      const cost_t* __restrict distance,
                      vid_t* frontier_list, vid_t* frontier_count) {
  const vid_t v = THREAD_GLOBAL_INDEX;
  if (v >= vertex_count) return;

  __shared__ vid_t queue_l[MAX_THREADS_PER_BLOCK];
  __shared__ vid_t count_l;
  count_l = 0;
  __syncthreads();

  if (distance[v] == level) {
    int index = atomicAdd(&count_l, 1);
    queue_l[index] = v;
  }
  __syncthreads();

  if (THREAD_BLOCK_INDEX >= count_l) return;

  __shared__ int index;
  if (THREAD_BLOCK_INDEX == 0) {
    index = atomicAdd(frontier_count, count_l);
  }
  __syncthreads();

  frontier_list[index + THREAD_BLOCK_INDEX] = queue_l[THREAD_BLOCK_INDEX];  
}

PRIVATE inline 
void build_frontier(partition_t* par, betweenness_state_t* state,
                    cost_t level) {
  cudaMemsetAsync(state->frontier_count, 0, sizeof(vid_t), par->streams[1]);
  dim3 blocks, threads;
  KERNEL_CONFIGURE(par->subgraph.vertex_count, blocks, threads);
  build_frontier_kernel<<<blocks, threads, 0, par->streams[1]>>>
    (par->subgraph.vertex_count, level, state->distance[par->id], 
     state->frontier_list, state->frontier_count);
  CALL_CU_SAFE(cudaGetLastError());
}

PRIVATE inline 
vid_t get_frontier_count(partition_t* par, betweenness_state_t* state) {
  vid_t frontier_count;
  CALL_CU_SAFE(cudaMemcpyAsync(&frontier_count, state->frontier_count,
                               sizeof(vid_t), cudaMemcpyDefault,
                               par->streams[1]));
  return frontier_count;
}

template<int VWARP_WIDTH, int VWARP_BATCH>
PRIVATE void forward_gpu(partition_t* par, betweenness_state_t* state, 
                         vid_t frontier_count) {
  dim3 blocks, threads;
  KERNEL_CONFIGURE(vwarp_thread_count(frontier_count,
                                      VWARP_WIDTH, VWARP_BATCH),
                   blocks, threads);
  betweenness_gpu_forward_kernel<VWARP_WIDTH, VWARP_BATCH>
    <<<blocks, threads, 0, par->streams[1]>>>(*par, *state);
  CALL_CU_SAFE(cudaGetLastError());
}

typedef void(*bc_gpu_func_t)(partition_t*, betweenness_state_t*, vid_t);
PRIVATE const bc_gpu_func_t FORWARD_GPU_FUNC[] = {
  // RANDOM partitioning
  forward_gpu<VWARP_MEDIUM_WARP_WIDTH,  VWARP_MEDIUM_BATCH_SIZE>,
  // HIGH partitioning
  forward_gpu<VWARP_MEDIUM_WARP_WIDTH,  VWARP_MEDIUM_BATCH_SIZE>,
  // LOW partitioning
  forward_gpu<MAX_THREADS_PER_BLOCK,  VWARP_MEDIUM_BATCH_SIZE>
};

/**
 * Entry point for forward propagation on the GPU
 */
PRIVATE inline void betweenness_forward_gpu(partition_t* par) {
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  engine_set_outbox(par->id, (int)0); 
  build_frontier(par, state, state->level);
  vid_t frontier_count = get_frontier_count(par, state);
  if (frontier_count == 0) return;
  // Call the corresponding cuda kernel to perform forward propagation
  // given the current state of the algorithm
  int par_alg = engine_partition_algorithm();
  FORWARD_GPU_FUNC[par_alg](par, state, frontier_count);
}

/**
 * Entry point for forward propagation on the CPU
 */
void betweenness_forward_cpu(partition_t* par) {
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  graph_t* subgraph = &par->subgraph;  
  cost_t* distance = state->distance[par->id];
  uint32_t* numSPs = state->numSPs[par->id];
  bool done = true;
  // In parallel, iterate over vertices which are at the current level
  OMP(omp parallel for schedule(runtime) reduction(& : done))
  for (vid_t v = 0; v < subgraph->vertex_count; v++) {
    if (distance[v] == state->level) {
      for (eid_t e = subgraph->vertices[v]; e < subgraph->vertices[v + 1]; 
           e++) {
        vid_t nbr = GET_VERTEX_ID(subgraph->edges[e]);
        int nbr_pid = GET_PARTITION_ID(subgraph->edges[e]);
        cost_t* nbr_distance = state->distance[nbr_pid];
        if (nbr_distance[nbr] == INF_COST) {
          nbr_distance[nbr] = state->level + 1;
          done = false;
        }
        if (nbr_distance[nbr] == state->level + 1) {
          uint32_t* nbr_numSPs = state->numSPs_f[nbr_pid];
          __sync_fetch_and_add(&nbr_numSPs[nbr], numSPs[v]); 
        }
      }
    }
  }
  // If there is remaining work to do, set the done flag to false
  if (!done) *(state->done) = false;
}

/**
 * Distributes work to either the CPU or GPU
 */
PRIVATE void betweenness_forward(partition_t* par) {
  // Check if there is no work to be done
  if (!par->subgraph.vertex_count) return;

  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;

  for (int pid = 0; pid < engine_partition_count(); pid++) {
    if (pid != par->id) {
      state->numSPs_f[pid] = (uint32_t*)par->outbox[pid].push_values;
    }
  }

  // Check which kind of processor this partition corresponds to and
  // call the appropriate function to perform forward propagation
  if (par->processor.type == PROCESSOR_CPU) {
    betweenness_forward_cpu(par);
  } else if (par->processor.type == PROCESSOR_GPU) {
    betweenness_forward_gpu(par);
  } else {
    assert(false);
  }
  // Increment the level for the next round of forward propagation
  state->level++;
}

/**
 * The neighbors backward propagation processing function. This function 
 * computes the delta of a vertex.
 */
template<int VWARP_WIDTH>
__device__ void
backward_process_neighbors(partition_t* par, betweenness_state_t* state,
                           const vid_t* __restrict nbrs, vid_t nbr_count,
                           uint32_t v_numSPs, score_t* vwarp_delta_s, vid_t v) {
  int warp_offset = vwarp_thread_index(VWARP_WIDTH);
  vwarp_delta_s[warp_offset] = 0;
  // Iterate through the portion of work
  for(vid_t i = warp_offset; i < nbr_count; i += VWARP_WIDTH) {
    vid_t nbr = GET_VERTEX_ID(nbrs[i]);
    int nbr_pid = GET_PARTITION_ID(nbrs[i]);
    cost_t* nbr_distance = state->distance[nbr_pid];  
    if (nbr_distance[nbr] == state->level + 1) {
      // Check whether the neighbour is local or remote and update accordingly
      // Compute an intermediary delta value in shared memory
      score_t* nbr_delta = state->delta[nbr_pid];
      uint32_t* nbr_numSPs = state->numSPs[nbr_pid];
      vwarp_delta_s[warp_offset] += 
        ((((score_t)v_numSPs) / ((score_t)nbr_numSPs[nbr])) * 
         (nbr_delta[nbr] + 1));
    }
  }

  // Perform prefix-sum to aggregate the final result
  if (VWARP_WIDTH > 32) __syncthreads();
  for (uint32_t s = VWARP_WIDTH / 2; s > 0; s >>= 1) {
    if (warp_offset < s) {
      vwarp_delta_s[warp_offset] += vwarp_delta_s[warp_offset + s];
    }
    __syncthreads();
  }
  if ((warp_offset == 0) && vwarp_delta_s[0]) {
    (state->delta[par->id])[v] = vwarp_delta_s[0];
    state->betweenness[v] += vwarp_delta_s[0];
  }
}

/**
 * CUDA kernel which performs backward propagation
 */
template<int VWARP_WIDTH, int VWARP_BATCH>
__global__ void
betweenness_gpu_backward_kernel(partition_t par, betweenness_state_t state) {
  vid_t frontier_count = *state.frontier_count;
  if (THREAD_GLOBAL_INDEX >= 
      vwarp_thread_count(frontier_count, VWARP_WIDTH, VWARP_BATCH)) return;

  const eid_t* __restrict vertices = par.subgraph.vertices;
  const vid_t* __restrict edges = par.subgraph.edges;
  const uint32_t* __restrict numSPs = state.numSPs[par.id];

  // Each thread in every warp has an entry in the following array which will be
  // used to calculate intermediary delta values in shared memory
  __shared__ score_t delta_s[MAX_THREADS_PER_BLOCK];
  const int index = THREAD_BLOCK_INDEX / VWARP_WIDTH;
  score_t* vwarp_delta_s = &delta_s[index * VWARP_WIDTH];

  vid_t start_vertex = vwarp_block_start_vertex(VWARP_WIDTH, VWARP_BATCH) + 
    vwarp_warp_start_vertex(VWARP_WIDTH, VWARP_BATCH);
  vid_t end_vertex = start_vertex +
    vwarp_warp_batch_size(frontier_count, VWARP_WIDTH, VWARP_BATCH);
  int warp_offset = vwarp_thread_index(VWARP_WIDTH);
  
  // Iterate over my work
  for(vid_t i = start_vertex; i < end_vertex; i++) {
    vid_t v = state.frontier_list[i];
    // If the vertex is at the current level, determine its contribution
    // to the source vertex's delta value
    const eid_t nbr_count = vertices[v + 1] - vertices[v];
    const vid_t* __restrict nbrs = &(edges[vertices[v]]);
    backward_process_neighbors<VWARP_WIDTH>
      (&par, &state, nbrs, nbr_count, numSPs[v], vwarp_delta_s, v);
  }
}

template<int VWARP_WIDTH, int VWARP_BATCH>
PRIVATE void backward_gpu(partition_t* par, betweenness_state_t* state,
                          vid_t frontier_count) {
  dim3 blocks, threads;
  KERNEL_CONFIGURE(vwarp_thread_count(frontier_count,
                                      VWARP_WIDTH, VWARP_BATCH), 
                   blocks, threads);
  betweenness_gpu_backward_kernel<VWARP_WIDTH, VWARP_BATCH>
    <<<blocks, threads, 0, par->streams[1]>>>(*par, *state);
  CALL_CU_SAFE(cudaGetLastError());
}

PRIVATE const bc_gpu_func_t BACKWARD_GPU_FUNC[] = {
  // RANDOM algorithm
  backward_gpu<VWARP_MEDIUM_WARP_WIDTH, VWARP_MEDIUM_BATCH_SIZE>,
  // HIGH partitioning
  backward_gpu<VWARP_MEDIUM_WARP_WIDTH, VWARP_MEDIUM_BATCH_SIZE>,
  // LOW partitioning
  backward_gpu<MAX_THREADS_PER_BLOCK,  VWARP_MEDIUM_BATCH_SIZE>
};

/**
 * Entry point for backward propagation on GPU
 */
PRIVATE inline void betweenness_backward_gpu(partition_t* par) {
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  // Given this state, invoke the CUDA kernel which performs
  // backward propagation
  build_frontier(par, state, state->level);
  vid_t frontier_count = get_frontier_count(par, state);
  if (frontier_count == 0) return;
  int par_alg = engine_partition_algorithm();
  BACKWARD_GPU_FUNC[par_alg](par, state, frontier_count);
}

/**
 * Entry point for backward propagation on CPU
 */
void betweenness_backward_cpu(partition_t* par) {
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  graph_t* subgraph = &par->subgraph;
  cost_t* distance = state->distance[par->id];
  uint32_t* numSPs = state->numSPs[par->id];
  score_t* delta = state->delta[par->id];

  // In parallel, iterate over vertices which are at the current level
  OMP(omp parallel for schedule(runtime))
  for (vid_t v = 0; v < subgraph->vertex_count; v++) {
    if (distance[v] == state->level) {
      // For all neighbors of v, iterate over paths
      for (eid_t e = subgraph->vertices[v]; e < subgraph->vertices[v + 1];
           e++) {
        vid_t nbr = GET_VERTEX_ID(subgraph->edges[e]);
        int nbr_pid = GET_PARTITION_ID(subgraph->edges[e]);
        cost_t* nbr_distance = state->distance[nbr_pid];
 
        // Check whether the neighbour is local or remote and update accordingly
        if (nbr_distance[nbr] == state->level + 1) {
          score_t* nbr_delta = state->delta[nbr_pid];
          uint32_t* nbr_numSPs = state->numSPs[nbr_pid];
          delta[v] += ((((score_t)(numSPs[v])) / ((score_t)(nbr_numSPs[nbr]))) *
                       (nbr_delta[nbr] + 1));
        }
      }
      // Add the dependency to the BC sum
      state->betweenness[v] += delta[v];
    }
  }
}

/**
 * Distributes work for backward propagation to either the CPU or GPU
 */
PRIVATE void betweenness_backward(partition_t* par) {
  // Check if there is no work to be done
  if (!par->subgraph.vertex_count) return;

  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;

  for (int pid = 0; pid < engine_partition_count(); pid++) {
    if (pid != par->id) {
      state->delta[pid] = (score_t*)par->outbox[pid].pull_values;
    }
  }

  if (engine_superstep() > 1) {
    // Check what kind of processing unit corresponds to this partition and
    // then call the appropriate function to perform backward propagation
    if (par->processor.type == PROCESSOR_CPU) {
      betweenness_backward_cpu(par);
    } else if (par->processor.type == PROCESSOR_GPU) {
      betweenness_backward_gpu(par);
    } else {
      assert(false);
    }
  }
  // Decrement the level for the next round of backward propagation
  state->level--;

  // Check whether backward propagation is finished
  if (state->level > 0) {
    engine_report_not_finished();
  }
}

/*
 * Parallel CPU implementation of betweenness scatter function
 */
PRIVATE inline void betweenness_scatter_cpu(int pid, grooves_box_table_t* inbox,
                                            betweenness_state_t* state) {
  cost_t* distance = state->distance[pid];
  uint32_t* numSPs = state->numSPs[pid];
  // Get the values that have been pushed to this vertex
  uint32_t* inbox_values = (uint32_t*)inbox->push_values;
  OMP(omp parallel for schedule(runtime))
  for (vid_t index = 0; index < inbox->count; index++) {
    if (inbox_values[index] != 0) {
      vid_t vid = inbox->rmt_nbrs[index];
      // If the distance was previously infinity, initialize it to the
      // current level 
      if (distance[vid] == INF_COST) {
        distance[vid] = state->level;
      }
      // If the distance is equal to the current level, update the 
      // nodes number of shortest paths with the pushed value
      if (distance[vid] == state->level) {
        numSPs[vid] += inbox_values[index];
      }
    }
  }
}

/*
 * Kernel for betweenness_scatter_gpu
 */
__global__ void betweenness_scatter_kernel(grooves_box_table_t inbox, 
                                           cost_t* distance, uint32_t* numSPs,
                                           cost_t level) {
  vid_t index = THREAD_GLOBAL_INDEX;
  if (index >= inbox.count) return;

  // Get the values that have been pushed to this vertex
  uint32_t* inbox_values = (uint32_t*)inbox.push_values;
  if (inbox_values[index] != 0) {
    vid_t vid = inbox.rmt_nbrs[index];
    // If the distance was previously infinity, initialize it to the
    // current level   
    if (distance[vid] == INF_COST) {
      distance[vid] = level;
    }
    // If the distance is equal to the current level, update the 
    // nodes number of shortest paths with the pushed value
    if (distance[vid] == level) {
      numSPs[vid] += inbox_values[index];
    }
  }
}

/*
 * Parallel GPU implementation of betweenness scatter function
 */
PRIVATE inline void betweenness_scatter_gpu(partition_t* par, 
                                            grooves_box_table_t* inbox,
                                            betweenness_state_t* state) {
  dim3 blocks, threads;
  KERNEL_CONFIGURE(inbox->count, blocks, threads);
  // Invoke the appropriate CUDA kernel to perform the scatter functionality
  betweenness_scatter_kernel<<<blocks, threads, 0, par->streams[1]>>>
    (*inbox, state->distance[par->id], state->numSPs[par->id], state->level);
  CALL_CU_SAFE(cudaGetLastError());
}

/**
 * Update the number of shortest paths from remote vertices
 * Also update distance if it has yet to be initialized
 */
PRIVATE void betweenness_scatter_forward(partition_t* par) {
  // Check if there is no work to be done
  if (!par->subgraph.vertex_count) return;

  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;

  for (int rmt_pid = 0; rmt_pid < engine_partition_count(); rmt_pid++) {
    if (rmt_pid == par->id) continue;
    // For all remote partitions, get the corresponding inbox
    grooves_box_table_t* inbox = &par->inbox[rmt_pid];
    if (!inbox->count) continue;
    // If the inbox has some values, determine which type of processing unit
    // corresponds to this partition and call the appropriate scatter function
    if (par->processor.type == PROCESSOR_CPU) {
      betweenness_scatter_cpu(par->id, inbox, state);
    } else if (par->processor.type == PROCESSOR_GPU) {
      betweenness_scatter_gpu(par, inbox, state);
    } else {
      assert(false);
    }
  }
}

/*
 * Parallel CPU implementation of betweenness gather function
 */
PRIVATE inline void betweenness_gather_cpu(int pid, grooves_box_table_t* inbox, 
                                           betweenness_state_t* state,
                                           score_t* values) {
  cost_t* distance = state->distance[pid];
  score_t* delta = state->delta[pid];
  OMP(omp parallel for schedule(runtime))
  for (vid_t index = 0; index < inbox->count; index++) {
    vid_t vid = inbox->rmt_nbrs[index];
    // Check whether the vertex's distance is equal to level + 1
    if (distance[vid] == (state->level + 1)) {
      // If it is, we'll pass the vertex's current delta value to neighbouring
      // nodes to be used during their next backward propagation phase
      values[index]  = delta[vid];
    }
  }
}

/*
 * Kernel for betweenness_gather_gpu
 */
__global__ 
void betweenness_gather_kernel(const vid_t* __restrict rmt_nbrs, 
                               const vid_t rmt_nbrs_count,
                               const cost_t* __restrict distance, 
                               const cost_t level, 
                               const score_t* __restrict delta, 
                               score_t* values) {
  vid_t index = THREAD_GLOBAL_INDEX;
  if (index >= rmt_nbrs_count) return;
  vid_t vid = rmt_nbrs[index];
  // Check whether the vertex's distance is equal to level + 1
  if (distance[vid] == level + 1) {
      // If it is, we'll pass the vertex's current delta value to neighbouring
      // nodes to be used during their next backward propagation phase
    values[index]  = delta[vid];
  }
}

/*
 * Parallel GPU implementation of betweenness gather function
 */
PRIVATE inline 
void betweenness_gather_gpu(partition_t* par, grooves_box_table_t* inbox,
                            betweenness_state_t* state, score_t* values) {
  dim3 blocks, threads;
  KERNEL_CONFIGURE(inbox->count, blocks, threads); 
  // Invoke the appropriate CUDA kernel to perform the gather functionality
  betweenness_gather_kernel<<<blocks, threads, 0, par->streams[1]>>>
    (inbox->rmt_nbrs, inbox->count, state->distance[par->id], 
     state->level, state->delta[par->id], values);
  CALL_CU_SAFE(cudaGetLastError());
}

/**
 * Pass the number of shortest paths and delta values to neighbouring
 * vertices to be used in the backwards propagation phase
 */
PRIVATE void betweenness_gather_backward(partition_t* par) {
  // Check if there is no work to be done
  if (!par->subgraph.vertex_count) return;

  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  
  for (int rmt_pid = 0; rmt_pid < engine_partition_count(); rmt_pid++) {
    if (rmt_pid == par->id) continue;
    grooves_box_table_t* inbox = &par->inbox[rmt_pid]; 
    // For all remote partitions, get the corresponding inbox
    if (!inbox->count) continue;
    score_t* values = (score_t*)inbox->pull_values;
    // If the inbox has some values, determine which type of processing unit
    // corresponds to this partition and call the appropriate gather function
    if (par->processor.type == PROCESSOR_CPU) {
      betweenness_gather_cpu(par->id, inbox, state, values);
    } else if (par->processor.type == PROCESSOR_GPU) {
      betweenness_gather_gpu(par, inbox, state, values);
    } else {
      assert(false);
    }   
  }
}

/**
 * Initializes the state for a round of backward propagation
 */
PRIVATE void betweenness_init_backward(partition_t* par) {
  if (!par->subgraph.vertex_count) return;
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  vid_t vcount = par->subgraph.vertex_count;

  // Determine which type of memory this partition corresponds to
  totem_mem_t type = TOTEM_MEM_HOST; 
  if (par->processor.type == PROCESSOR_GPU) { 
    type = TOTEM_MEM_DEVICE;
  }

  // Initialize the delta values to 0
  CALL_SAFE(totem_memset(state->delta[par->id], (score_t)0, vcount, type, 
                         par->streams[1]));
}

/**
 * Initializes the state for a round of forward propagation
 */
PRIVATE void betweenness_init_forward(partition_t* par) {
  if (!par->subgraph.vertex_count) return;
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  // Get the source partition and source vertex values
  id_t src_pid = GET_PARTITION_ID(bc_g.src);
  id_t src_vid = GET_VERTEX_ID(bc_g.src);
  vid_t vcount = par->subgraph.vertex_count;

  // Determine which type of memory this partition corresponds to
  totem_mem_t type = TOTEM_MEM_HOST; 
  if (par->processor.type == PROCESSOR_GPU) { 
    type = TOTEM_MEM_DEVICE;
  }

  // Initialize the distances to infinity and numSPs to 0
  for (int pid = 0; pid < engine_partition_count(); pid++) {
    vid_t count = (pid != par->id) ? par->outbox[pid].count : vcount;
    if (count) {
      CALL_SAFE(totem_memset((state->distance[pid]), INF_COST, count, type, 
                             par->streams[1]));
      CALL_SAFE(totem_memset((state->numSPs[pid]), (uint32_t)0, count, type, 
                             par->streams[1]));
    }
  }
  if (src_pid == par->id) {
    // For the source vertex, initialize its own distance and numSPs
    CALL_SAFE(totem_memset(&((state->distance[par->id])[src_vid]), (cost_t)0,
                           1, type, par->streams[1]));
    CALL_SAFE(totem_memset(&((state->numSPs[par->id])[src_vid]), (uint32_t)1,
                           1, type, par->streams[1]));
  }
  
  // Initialize the outbox to 0 and set the level to 0
  engine_set_outbox(par->id, 0); 
  state->level = 0;
}

/**
 * Allocates and initializes the state for Betweenness Centrality
 */
PRIVATE void betweenness_init(partition_t* par) {
  if (!par->subgraph.vertex_count) return;
  // Allocate memory for the per-partition state
  betweenness_state_t* state = (betweenness_state_t*)
                               calloc(1, sizeof(betweenness_state_t));
  assert(state); 
  // Set the partition's state variable to the previously allocated state
  par->algo_state = state;
  vid_t vcount = par->subgraph.vertex_count;

  // Determine which type of memory this partition corresponds to
  totem_mem_t type = TOTEM_MEM_HOST; 
  if (par->processor.type == PROCESSOR_GPU) { 
    type = TOTEM_MEM_DEVICE;
    CALL_SAFE(totem_calloc(vcount * sizeof(vid_t), type, 
                           (void **)&state->frontier_list));
    CALL_SAFE(totem_calloc(sizeof(vid_t), type, 
                           (void **)&state->frontier_count));
  }
  
  CALL_SAFE(totem_calloc(vcount * sizeof(score_t), type,
                         (void**)&(state->delta[par->id])));
  CALL_SAFE(totem_calloc(vcount * sizeof(score_t), type,
                         (void**)&(state->betweenness)));

  // Allocate memory for the various pieces of data required for the
  // Betweenness Centrality algorithm
  for (int pid = 0; pid < engine_partition_count(); pid++) {
    vid_t count = (pid != par->id) ? par->outbox[pid].count : vcount;
    if (count) {
      CALL_SAFE(totem_malloc(count * sizeof(cost_t), type, 
                             (void**)&(state->distance[pid])));
      CALL_SAFE(totem_calloc(count * sizeof(uint32_t), type, 
                             (void**)&(state->numSPs[pid])));
    }    
    state->numSPs_f[pid] = state->numSPs[pid];
  }

  // Initialize the state's done flag
  state->done = engine_get_finished_ptr(par->id);

  // Initialize the state
  betweenness_init_forward(par);
}

/**
 * Cleans up allocated memory on the CPU and GPU
 */
PRIVATE void betweenness_finalize(partition_t* par) {
  // Check if there is no work to be done
  if (!par->subgraph.vertex_count) return;  

  // Free the allocated memory
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
 
  // Determine which type of memory this partition corresponds to
  totem_mem_t type = TOTEM_MEM_HOST; 
  if (par->processor.type == PROCESSOR_GPU) { 
    type = TOTEM_MEM_DEVICE; 
    totem_free(state->frontier_list, type);
    totem_free(state->frontier_count, type);
  }

  // Free the memory allocated for the algorithm
  for (int pid = 0; pid < engine_partition_count(); pid++) {
    totem_free(state->distance[pid], type);
    totem_free(state->numSPs[pid], type);
  }
  totem_free(state->delta[par->id], type);
  totem_free(state->betweenness, type);

  // Free the per-partition state and set it to NULL
  free(state);
  par->algo_state = NULL;
}

/**
 * Aggregates the final result to be returned at the end
 */
PRIVATE void betweenness_aggr(partition_t* par) {  
  if (!par->subgraph.vertex_count) return;
  // Get the current state of the algorithm
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  graph_t* subgraph = &par->subgraph;
  score_t* betweenness_values = NULL;
  // Determine which type of processor this partition corresponds to
  if (par->processor.type == PROCESSOR_CPU) {
    // If it is a CPU partition, grab the computed betweenness value directly
    betweenness_values = state->betweenness;
  } else if (par->processor.type == PROCESSOR_GPU) {
    // If it is a GPU partition, copy the computed score back to the host
    assert(bc_g.betweenness_score_h);
    CALL_CU_SAFE(cudaMemcpy(bc_g.betweenness_score_h, state->betweenness, 
                            subgraph->vertex_count * sizeof(score_t),
                            cudaMemcpyDefault));
    betweenness_values = bc_g.betweenness_score_h;
  } else {
    assert(false);
  }
  // Aggregate the results
  assert(bc_g.betweenness_score);
  OMP(omp parallel for schedule(static))
  for (vid_t v = 0; v < subgraph->vertex_count; v++) {
    // Check whether we are computing exact centrality values
    if (bc_g.epsilon == CENTRALITY_EXACT) {
      // Return the exact values computed
      bc_g.betweenness_score[par->map[v]] = betweenness_values[v];
    }
    else {
      // Scale the computed Betweenness Centrality metrics since they were
      // computed using a subset of the total nodes within the graph
      // The scaling value is: (Total Number of Nodes / Subset of Nodes Used)
      bc_g.betweenness_score[par->map[v]] = betweenness_values[v] *
        (score_t)(((double)(engine_vertex_count())) / bc_g.num_samples); 
    }
  }
}

/**
 * The following two functions are the kernel and gather callbacks of a single 
 * BSP cycle that synchronizes the distance of remote vertices
 */
PRIVATE void betweenness_gather_distance(partition_t* par) {
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  engine_gather_inbox(par->id, state->distance[par->id]);
}
PRIVATE void betweenness_synch_distance(partition_t* par) {
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  if (engine_superstep() == 1) {
    engine_report_not_finished();
  } else {
    for (int rmt_pid = 0; rmt_pid < engine_partition_count(); rmt_pid++) {
      if (par->id == rmt_pid) continue;
      CALL_CU_SAFE(cudaMemcpyAsync(state->distance[rmt_pid], 
                                   par->outbox[rmt_pid].pull_values,
                                   par->outbox[rmt_pid].count * sizeof(cost_t),
                                   cudaMemcpyDefault, par->streams[1]));
    }
  }
}

/**
 * The following two functions are the kernel and gather callbacks of a single 
 * BSP cycle that synchronizes the numSPs of remote vertices
 */
PRIVATE void betweenness_gather_numSPs(partition_t* par) {
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  engine_gather_inbox(par->id, state->numSPs[par->id]);
}
PRIVATE void betweenness_synch_numSPs(partition_t* par) {
  betweenness_state_t* state = (betweenness_state_t*)par->algo_state;
  assert(state);
  if (engine_superstep() == 1) {
    engine_report_not_finished();
  } else {
    for (int rmt_pid = 0; rmt_pid < engine_partition_count(); rmt_pid++) {
      if (par->id == rmt_pid) continue;
      CALL_CU_SAFE(cudaMemcpyAsync(state->numSPs[rmt_pid], 
                                   par->outbox[rmt_pid].pull_values,
                                   par->outbox[rmt_pid].count * 
                                   sizeof(uint32_t),
                                   cudaMemcpyDefault, par->streams[1]));
    }
  }
}

/**
 * Core functionality for main for loop within the BC computation
 */
void betweenness_hybrid_core(vid_t source, bool is_first_iteration,
                             bool is_last_iteration) {
  // Set the source node for this iteration
  bc_g.src  = engine_vertex_id_in_partition(source);

  // Forward propagation
  engine_par_init_func_t init_forward = betweenness_init_forward;
  if (is_first_iteration) {
    init_forward = betweenness_init;
  }
  // Configure the parameters for forward propagation given the current
  // iteration of the overall computation
  engine_config_t config_forward = {
    NULL, betweenness_forward, betweenness_scatter_forward, NULL, 
    init_forward, NULL, NULL, GROOVES_PUSH
  };
  // Call Totem to begin the computation phase given the specified 
  // configuration
  engine_config(&config_forward);
  engine_execute();

  // Synchronize the distance and numSPs state, which have been calculated in
  // the forward phase, across all partitions. This state will be used in the
  // backward propagation phase
  engine_config_t config_distance_state = {
    NULL, betweenness_synch_distance, NULL, betweenness_gather_distance,
    NULL, NULL, NULL, GROOVES_PULL
  };
  engine_config(&config_distance_state);
  engine_execute();
  engine_config_t config_numSPs_state = {
    NULL, betweenness_synch_numSPs, NULL, betweenness_gather_numSPs,
    NULL, NULL, NULL, GROOVES_PULL
  };
  engine_config(&config_numSPs_state);
  engine_execute();

  // Backward propagation
  engine_par_finalize_func_t finalize_backward = NULL;
  engine_par_aggr_func_t aggr_backward = NULL;
  if (is_last_iteration) {
    finalize_backward = betweenness_finalize;
    aggr_backward = betweenness_aggr;
  }
  // Configure the parameters for backward propagation given the current
  // iteration of the overall computation
  engine_config_t config_backward = {
    NULL, betweenness_backward, NULL, betweenness_gather_backward,
    betweenness_init_backward, finalize_backward, aggr_backward, GROOVES_PULL
  };
  // Call Totem to begin the computation phase given the specified
  // configuration
  engine_config(&config_backward);
  engine_execute();
}

/**
 * Main function for hybrid betweenness centrality
 */
error_t betweenness_hybrid(double epsilon, score_t* betweenness_score) {
  // Sanity check on input
  bool finished = false;
  error_t rc = betweenness_check_special_cases(engine_get_graph(), 
                                               &finished, betweenness_score);
  if (finished) return rc;

  // Initialize the global state
  memset(&bc_g, 0, sizeof(bc_g));
  bc_g.betweenness_score = betweenness_score;
  CALL_SAFE(totem_memset(bc_g.betweenness_score, (score_t)0, 
                         engine_vertex_count(), TOTEM_MEM_HOST));
  bc_g.epsilon = epsilon;

  if (engine_largest_gpu_partition()) {
    CALL_SAFE(totem_malloc(engine_largest_gpu_partition() * sizeof(score_t),
                           TOTEM_MEM_HOST_PINNED, 
                           (void**)&bc_g.betweenness_score_h));
  }

  // Determine whether we will compute exact or approximate BC values
  if (epsilon == CENTRALITY_EXACT) {
    // Compute exact values for Betweenness Centrality
    vid_t vcount = engine_vertex_count();
    for (vid_t source = 0; source < vcount; source++) { 
      betweenness_hybrid_core(source, (source == 0), (source == (vcount-1)));  
    }
  } else {
    // Compute approximate values based on the value of epsilon provided
    // Select a subset of source nodes to make the computation faster
    int num_samples = centrality_get_number_sample_nodes(engine_vertex_count(),
                                                         epsilon);
    // Store the number of samples used in the global state to be used for 
    // scaling the computed metric during aggregation
    bc_g.num_samples = num_samples;
    // Populate the array of indices to sample
    vid_t* sample_nodes = centrality_select_sampling_nodes(
                          engine_get_graph(), num_samples);
 
    for (int source_index = 0; source_index < num_samples; source_index++) {
      // Get the next sample node in the array to use as a source
      vid_t source = sample_nodes[source_index];    
      betweenness_hybrid_core(source, (source_index == 0), 
                              (source_index == (num_samples-1)));  
    } 
 
    // Clean up the allocated memory
    free(sample_nodes);
  }
 
  // Clean up and return
  if (engine_largest_gpu_partition()) { 
    totem_free(bc_g.betweenness_score_h, TOTEM_MEM_HOST_PINNED);
  }
  memset(&bc_g, 0, sizeof(betweenness_global_state_t));
  return SUCCESS;
}
