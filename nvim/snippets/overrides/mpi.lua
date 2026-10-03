-- =============================================================================
-- snippets/overrides/mpi.lua -- hand-authored MPI facts no source on this box has
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- `mpi.mod` knows the shape of every routine and nothing about its meaning;
-- the shipped prose knows the meaning of 41 of them and carries a `Standard`
-- line for none. Neither can say which MPI version introduced a call -- the
-- single most useful fact when a program has to build on an old cluster, and
-- the biggest gap the port inherited (26 of 136 entries had a version).
--
-- So this file carries exactly three things:
--   * `standard` -- the MPI version that introduced the routine or constant;
--   * `summary` (+ `see_also`) for routines the prose never covered but this
--     project's code actually calls;
--   * full entries for the constants that have no `parameter` line to scrape
--     (MPI_STATUS_IGNORE, MPI_IN_PLACE are COMMON-block sentinels) and for the
--     handful worth an A5-quality hover.
--
-- `href` is NOT here: gen-mpi.lua derives the Open MPI man-page URL for every
-- routine from its display name, so only an exception would belong here, and
-- there are none.
--
-- NOTHING HERE MAY CARRY `interface`, `signature`, `result_type` or `value` on
-- a procedure or a constant: gen-mpi.lua DIES on those keys rather than merely
-- declining to overwrite them. Declining was not enough -- a constant has no
-- `interface` for the old rule to protect, so an override carrying one used to
-- be injected whole, and every inlay hint built from it would name dummies no
-- `.mod` ever vouched for. Argument order comes from the compiler, always.
-- `kind` is likewise the compiler's wherever the compiler has one; the entries
-- below that spell it are the ones no machine source knows (`mpi_f08`, the
-- COMMON-block sentinels), where the override IS the only source.
--
-- Merge order in gen-mpi.lua: machine source -> parsed prose -> this file.
-- A key that no machine source and no prose knows is ADDED whole.

local S1 = "MPI-1.0"
local S2 = "MPI-2.0"
local S22 = "MPI-2.2"
local S3 = "MPI-3.0"
local S31 = "MPI-3.1"
local S4 = "MPI-4.0"

local O = {}

--- Attach `standard` to a list of lowercase entry names.
local function std(version, names)
  for _, n in ipairs(names) do
    O[n] = O[n] or {}
    O[n].standard = version
  end
end

-- ---------------------------------------------------------------------------
-- Standards
-- ---------------------------------------------------------------------------

std(S1, {
  "mpi_abort", "mpi_allgather", "mpi_allgatherv", "mpi_allreduce", "mpi_alltoall",
  "mpi_alltoallv", "mpi_barrier", "mpi_bcast", "mpi_bsend",
  "mpi_bsend_init", "mpi_buffer_attach", "mpi_buffer_detach", "mpi_cancel",
  "mpi_cart_coords", "mpi_cart_create", "mpi_cart_get", "mpi_cart_map",
  "mpi_cart_rank", "mpi_cart_shift", "mpi_cart_sub", "mpi_cartdim_get",
  "mpi_comm_compare", "mpi_comm_create", "mpi_comm_dup", "mpi_comm_free",
  "mpi_comm_group", "mpi_comm_rank", "mpi_comm_remote_group",
  "mpi_comm_remote_size", "mpi_comm_size", "mpi_comm_split", "mpi_comm_test_inter",
  "mpi_dims_create", "mpi_errhandler_free", "mpi_error_class", "mpi_error_string",
  "mpi_finalize", "mpi_gather", "mpi_gatherv", "mpi_get_count", "mpi_get_elements",
  "mpi_get_processor_name", "mpi_graph_create", "mpi_graph_get", "mpi_graph_map",
  "mpi_graph_neighbors", "mpi_graph_neighbors_count", "mpi_graphdims_get",
  "mpi_group_compare", "mpi_group_difference", "mpi_group_excl", "mpi_group_free",
  "mpi_group_incl", "mpi_group_intersection", "mpi_group_range_excl",
  "mpi_group_range_incl", "mpi_group_rank", "mpi_group_size",
  "mpi_group_translate_ranks", "mpi_group_union", "mpi_ibsend", "mpi_init",
  "mpi_initialized", "mpi_intercomm_create", "mpi_intercomm_merge", "mpi_iprobe",
  "mpi_irecv", "mpi_irsend", "mpi_isend", "mpi_issend", "mpi_op_create",
  "mpi_op_free", "mpi_pack", "mpi_pack_size", "mpi_pcontrol", "mpi_probe",
  "mpi_recv", "mpi_recv_init", "mpi_reduce", "mpi_reduce_scatter",
  "mpi_request_free", "mpi_rsend", "mpi_rsend_init", "mpi_scan", "mpi_scatter",
  "mpi_scatterv", "mpi_send", "mpi_send_init", "mpi_sendrecv",
  "mpi_sendrecv_replace", "mpi_ssend", "mpi_ssend_init", "mpi_start",
  "mpi_startall", "mpi_test", "mpi_test_cancelled", "mpi_testall", "mpi_testany",
  "mpi_testsome", "mpi_topo_test", "mpi_type_commit", "mpi_type_contiguous",
  "mpi_type_free", "mpi_type_indexed", "mpi_type_size", "mpi_type_vector",
  "mpi_unpack", "mpi_wait", "mpi_waitall", "mpi_waitany", "mpi_waitsome",
  "mpi_wtick", "mpi_wtime",
})

std(S2, {
  "mpi_alloc_mem", "mpi_close_port", "mpi_comm_accept", "mpi_comm_call_errhandler",
  "mpi_comm_connect", "mpi_comm_create_errhandler", "mpi_comm_create_keyval",
  "mpi_comm_delete_attr", "mpi_comm_disconnect", "mpi_comm_free_keyval",
  "mpi_comm_get_attr", "mpi_comm_get_errhandler", "mpi_comm_get_name",
  "mpi_comm_get_parent", "mpi_comm_join", "mpi_comm_set_attr",
  "mpi_comm_set_errhandler", "mpi_comm_set_name", "mpi_comm_spawn",
  "mpi_comm_spawn_multiple", "mpi_exscan", "mpi_file_call_errhandler",
  "mpi_file_close", "mpi_file_create_errhandler", "mpi_file_delete",
  "mpi_file_get_amode", "mpi_file_get_atomicity", "mpi_file_get_byte_offset",
  "mpi_file_get_errhandler", "mpi_file_get_group", "mpi_file_get_info",
  "mpi_file_get_position", "mpi_file_get_position_shared", "mpi_file_get_size",
  "mpi_file_get_type_extent", "mpi_file_get_view", "mpi_file_iread",
  "mpi_file_iread_at", "mpi_file_iread_shared", "mpi_file_iwrite",
  "mpi_file_iwrite_at", "mpi_file_iwrite_shared", "mpi_file_open",
  "mpi_file_preallocate", "mpi_file_read", "mpi_file_read_all",
  "mpi_file_read_all_begin", "mpi_file_read_all_end", "mpi_file_read_at",
  "mpi_file_read_at_all", "mpi_file_read_at_all_begin", "mpi_file_read_at_all_end",
  "mpi_file_read_ordered", "mpi_file_read_ordered_begin",
  "mpi_file_read_ordered_end", "mpi_file_read_shared", "mpi_file_seek",
  "mpi_file_seek_shared", "mpi_file_set_atomicity", "mpi_file_set_errhandler",
  "mpi_file_set_info", "mpi_file_set_size", "mpi_file_set_view", "mpi_file_sync",
  "mpi_file_write", "mpi_file_write_all", "mpi_file_write_all_begin",
  "mpi_file_write_all_end", "mpi_file_write_at", "mpi_file_write_at_all",
  "mpi_file_write_at_all_begin", "mpi_file_write_at_all_end",
  "mpi_file_write_ordered", "mpi_file_write_ordered_begin",
  "mpi_file_write_ordered_end", "mpi_file_write_shared", "mpi_finalized",
  "mpi_free_mem", "mpi_get", "mpi_get_address", "mpi_get_version",
  "mpi_grequest_complete", "mpi_grequest_start", "mpi_info_create",
  "mpi_info_delete", "mpi_info_dup", "mpi_info_free", "mpi_info_get",
  "mpi_info_get_nkeys", "mpi_info_get_nthkey", "mpi_info_get_valuelen",
  "mpi_info_set", "mpi_init_thread", "mpi_is_thread_main", "mpi_lookup_name",
  "mpi_open_port", "mpi_pack_external", "mpi_pack_external_size", "mpi_publish_name",
  "mpi_put", "mpi_query_thread", "mpi_register_datarep", "mpi_request_get_status",
  "mpi_sizeof", "mpi_status_set_cancelled", "mpi_status_set_elements",
  "mpi_type_create_darray", "mpi_type_create_f90_complex",
  "mpi_type_create_f90_integer", "mpi_type_create_f90_real",
  "mpi_type_create_hindexed", "mpi_type_create_hvector",
  "mpi_type_create_indexed_block", "mpi_type_create_keyval",
  "mpi_type_create_resized", "mpi_type_create_struct", "mpi_type_create_subarray",
  "mpi_type_delete_attr", "mpi_type_dup", "mpi_type_free_keyval",
  "mpi_type_get_attr", "mpi_type_get_contents", "mpi_type_get_envelope",
  "mpi_type_get_extent", "mpi_type_get_name", "mpi_type_get_true_extent",
  "mpi_type_match_size", "mpi_type_set_attr", "mpi_type_set_name",
  "mpi_unpack_external", "mpi_unpublish_name", "mpi_win_call_errhandler",
  "mpi_win_complete", "mpi_win_create", "mpi_win_create_errhandler",
  "mpi_win_create_keyval", "mpi_win_delete_attr", "mpi_win_fence", "mpi_win_free",
  "mpi_win_free_keyval", "mpi_win_get_attr", "mpi_win_get_errhandler",
  "mpi_win_get_group", "mpi_win_get_name", "mpi_win_lock", "mpi_win_post",
  "mpi_win_set_attr", "mpi_win_set_errhandler", "mpi_win_set_name",
  "mpi_win_start", "mpi_win_test", "mpi_win_unlock", "mpi_win_wait",
})

std(S22, {
  "mpi_dist_graph_create", "mpi_dist_graph_create_adjacent",
  "mpi_dist_graph_neighbors", "mpi_dist_graph_neighbors_count",
  "mpi_op_commutative", "mpi_reduce_local",
})

std(S3, {
  "mpi_comm_create_group", "mpi_comm_idup", "mpi_comm_split_type",
  "mpi_compare_and_swap", "mpi_fetch_and_op", "mpi_get_accumulate",
  "mpi_get_elements_x", "mpi_get_library_version", "mpi_iallgather",
  "mpi_iallgatherv", "mpi_iallreduce", "mpi_ialltoall", "mpi_ialltoallv",
  "mpi_ialltoallw", "mpi_ibarrier", "mpi_ibcast", "mpi_iexscan", "mpi_igather",
  "mpi_igatherv", "mpi_improbe", "mpi_imrecv", "mpi_ineighbor_allgather",
  "mpi_ineighbor_allgatherv", "mpi_ineighbor_alltoall", "mpi_ineighbor_alltoallv",
  "mpi_ineighbor_alltoallw", "mpi_ireduce", "mpi_ireduce_scatter",
  "mpi_ireduce_scatter_block", "mpi_iscan", "mpi_iscatter", "mpi_iscatterv",
  "mpi_mprobe", "mpi_mrecv", "mpi_neighbor_allgather", "mpi_neighbor_allgatherv",
  "mpi_neighbor_alltoall", "mpi_neighbor_alltoallv", "mpi_neighbor_alltoallw",
  "mpi_raccumulate", "mpi_reduce_scatter_block", "mpi_rget", "mpi_rget_accumulate",
  "mpi_rput", "mpi_status_set_elements_x", "mpi_type_create_hindexed_block",
  "mpi_type_get_extent_x", "mpi_type_get_true_extent_x", "mpi_type_size_x",
  "mpi_win_allocate", "mpi_win_allocate_shared", "mpi_win_attach",
  "mpi_win_create_dynamic", "mpi_win_detach", "mpi_win_flush", "mpi_win_flush_all",
  "mpi_win_flush_local", "mpi_win_flush_local_all", "mpi_win_get_info",
  "mpi_win_lock_all", "mpi_win_set_info", "mpi_win_shared_query", "mpi_win_sync",
  "mpi_win_unlock_all",
})

std(S31, { "mpi_aint_add", "mpi_aint_diff" })

std(S4, {
  "mpi_allgather_init", "mpi_allgatherv_init", "mpi_allreduce_init",
  "mpi_alltoall_init", "mpi_alltoallv_init", "mpi_alltoallw_init",
  "mpi_barrier_init", "mpi_bcast_init", "mpi_exscan_init", "mpi_gather_init", "mpi_gatherv_init",
  "mpi_info_create_env", "mpi_info_get_string",
  "mpi_isendrecv", "mpi_isendrecv_replace",
  "mpi_neighbor_allgather_init", "mpi_neighbor_allgatherv_init",
  "mpi_neighbor_alltoall_init", "mpi_neighbor_alltoallv_init",
  "mpi_neighbor_alltoallw_init", "mpi_parrived", "mpi_pready", "mpi_pready_list",
  "mpi_pready_range", "mpi_precv_init", "mpi_psend_init", "mpi_reduce_init",
  "mpi_reduce_scatter_block_init", "mpi_reduce_scatter_init", "mpi_scan_init",
  "mpi_scatter_init", "mpi_scatterv_init", "mpi_session_call_errhandler",
  "mpi_session_create_errhandler", "mpi_session_finalize",
  "mpi_session_get_errhandler", "mpi_session_set_errhandler",
})


std(S1, { "mpi_dup_fn", "mpi_null_copy_fn", "mpi_null_delete_fn" })

std(S2, {
  "mpi_accumulate", "mpi_add_error_class", "mpi_add_error_code",
  "mpi_add_error_string", "mpi_alltoallw", "mpi_comm_dup_fn",
  "mpi_comm_null_copy_fn", "mpi_comm_null_delete_fn", "mpi_type_dup_fn",
  "mpi_type_null_copy_fn", "mpi_type_null_delete_fn", "mpi_win_dup_fn",
  "mpi_win_null_copy_fn", "mpi_win_null_delete_fn",
})

std(S3, {
  "mpi_comm_dup_with_info", "mpi_comm_get_info", "mpi_comm_set_info",
  "mpi_conversion_fn_null", "mpi_f_sync_reg",
})

std(S31, {
  "mpi_file_iread_all", "mpi_file_iread_at_all", "mpi_file_iwrite_all",
  "mpi_file_iwrite_at_all",
})

std(S4, { "mpi_comm_idup_with_info", "mpi_status_f082f", "mpi_status_f2f08" })

-- ---------------------------------------------------------------------------
-- Summaries for routines the shipped prose never covered
-- ---------------------------------------------------------------------------
--
-- Scope: what this project calls, plus the immediate neighbour of each. A
-- summary is ONE sentence and no more; the description is left to the prose or
-- to a later pass, because a wrong description is worse than none.

local function sum(name, summary, see_also)
  O[name] = O[name] or {}
  O[name].summary = summary
  if see_also then
    O[name].see_also = see_also
  end
end

sum("mpi_test", "Test whether a nonblocking operation has completed, without blocking",
  { "MPI_Wait", "MPI_Testall", "MPI_Request_free" })
sum("mpi_testall", "Test whether every request in an array has completed",
  { "MPI_Waitall", "MPI_Test" })
sum("mpi_testany", "Test whether any one request in an array has completed",
  { "MPI_Waitany", "MPI_Test" })
sum("mpi_testsome", "Test which of an array of requests have completed",
  { "MPI_Waitsome", "MPI_Testany" })
sum("mpi_waitany", "Block until any one request in an array completes",
  { "MPI_Waitall", "MPI_Testany" })
sum("mpi_waitsome", "Block until at least one of an array of requests completes",
  { "MPI_Waitall", "MPI_Testsome" })
sum("mpi_request_free", "Release a request handle without waiting for completion",
  { "MPI_Wait", "MPI_Cancel" })
sum("mpi_cancel", "Ask to cancel a pending nonblocking operation",
  { "MPI_Request_free", "MPI_Test_cancelled" })

sum("mpi_ssend", "Synchronous send: returns only once the matching receive has started",
  { "MPI_Send", "MPI_Issend" })
sum("mpi_bsend", "Buffered send: copies the message into a user-supplied buffer and returns",
  { "MPI_Send", "MPI_Buffer_attach" })
sum("mpi_rsend", "Ready send: valid only when the matching receive is already posted",
  { "MPI_Send", "MPI_Irsend" })
sum("mpi_sendrecv_replace", "Send and receive using one buffer for both",
  { "MPI_Sendrecv" })
sum("mpi_send_init", "Create a persistent send request, to be fired with MPI_Start",
  { "MPI_Start", "MPI_Recv_init" })
sum("mpi_recv_init", "Create a persistent receive request, to be fired with MPI_Start",
  { "MPI_Start", "MPI_Send_init" })
sum("mpi_start", "Fire one persistent request created by MPI_Send_init or MPI_Recv_init",
  { "MPI_Startall", "MPI_Send_init" })
sum("mpi_startall", "Fire a whole array of persistent requests",
  { "MPI_Start", "MPI_Waitall" })

sum("mpi_gatherv", "Gather a varying number of elements from each rank to the root",
  { "MPI_Gather", "MPI_Scatterv" })
sum("mpi_scatterv", "Scatter a varying number of elements from the root to each rank",
  { "MPI_Scatter", "MPI_Gatherv" })
sum("mpi_allgatherv", "Gather varying counts from every rank to every rank",
  { "MPI_Allgather", "MPI_Gatherv" })
sum("mpi_alltoallv", "Exchange a varying number of elements between every pair of ranks",
  { "MPI_Alltoall", "MPI_Scatterv" })
sum("mpi_reduce_scatter", "Reduce across ranks and scatter the result",
  { "MPI_Reduce", "MPI_Scatterv" })
sum("mpi_reduce_scatter_block", "Reduce across ranks and scatter equal-sized blocks of the result",
  { "MPI_Reduce_scatter", "MPI_Allreduce" })
sum("mpi_exscan", "Exclusive prefix reduction across the ranks of a communicator",
  { "MPI_Scan", "MPI_Reduce" })
sum("mpi_ibarrier", "Nonblocking barrier: returns at once and completes through a request",
  { "MPI_Barrier", "MPI_Wait" })
sum("mpi_ibcast", "Nonblocking broadcast", { "MPI_Bcast", "MPI_Wait" })
sum("mpi_iallreduce", "Nonblocking all-reduce", { "MPI_Allreduce", "MPI_Wait" })
sum("mpi_ireduce", "Nonblocking reduction to a root", { "MPI_Reduce", "MPI_Wait" })
sum("mpi_igather", "Nonblocking gather to a root", { "MPI_Gather", "MPI_Wait" })
sum("mpi_iscatter", "Nonblocking scatter from a root", { "MPI_Scatter", "MPI_Wait" })
sum("mpi_iallgather", "Nonblocking all-gather", { "MPI_Allgather", "MPI_Wait" })
sum("mpi_ialltoall", "Nonblocking all-to-all exchange", { "MPI_Alltoall", "MPI_Wait" })
sum("mpi_reduce_local", "Apply a reduction operation locally, with no communication",
  { "MPI_Reduce", "MPI_Op_create" })

sum("mpi_type_vector", "Build a datatype from equally spaced blocks of an existing type",
  { "MPI_Type_contiguous", "MPI_Type_commit" })
sum("mpi_type_indexed", "Build a datatype from blocks at arbitrary element displacements",
  { "MPI_Type_create_hindexed", "MPI_Type_commit" })
sum("mpi_type_create_hvector", "Like MPI_Type_vector, with the stride given in bytes",
  { "MPI_Type_vector", "MPI_Get_address" })
sum("mpi_type_create_hindexed", "Like MPI_Type_indexed, with displacements given in bytes",
  { "MPI_Type_indexed", "MPI_Get_address" })
sum("mpi_type_create_struct", "Build a datatype from blocks of differing types and displacements",
  { "MPI_Get_address", "MPI_Type_commit" })
sum("mpi_type_create_resized", "Change the lower bound and extent of a datatype",
  { "MPI_Type_get_extent", "MPI_Type_commit" })
sum("mpi_type_create_subarray", "Build a datatype describing a sub-block of a multidimensional array",
  { "MPI_Type_create_darray", "MPI_Type_commit" })
sum("mpi_type_size", "Number of bytes the data of one element of a datatype occupies",
  { "MPI_Type_get_extent", "MPI_Get_count" })
sum("mpi_type_get_extent", "Lower bound and extent of a datatype, in bytes",
  { "MPI_Type_size", "MPI_Type_create_resized" })
sum("mpi_type_dup", "Duplicate a datatype, attributes included", { "MPI_Type_commit" })
sum("mpi_get_address", "Byte address of a variable, for use in datatype displacements",
  { "MPI_Type_create_struct", "MPI_Aint_add" })
sum("mpi_pack", "Pack data into a contiguous buffer for MPI_PACKED transmission",
  { "MPI_Unpack", "MPI_Pack_size" })
sum("mpi_unpack", "Unpack data from an MPI_PACKED buffer", { "MPI_Pack" })
sum("mpi_pack_size", "Upper bound on the space MPI_Pack needs for a message",
  { "MPI_Pack" })

sum("mpi_initialized", "Test whether MPI_Init has already been called",
  { "MPI_Init", "MPI_Finalized" })
sum("mpi_finalized", "Test whether MPI_Finalize has already been called",
  { "MPI_Finalize", "MPI_Initialized" })
sum("mpi_query_thread", "The level of thread support the MPI library actually provided",
  { "MPI_Init_thread", "MPI_Is_thread_main" })
sum("mpi_is_thread_main", "Test whether the calling thread is the one that called MPI_Init",
  { "MPI_Init_thread", "MPI_Query_thread" })
sum("mpi_get_version", "The MPI standard version the library implements",
  { "MPI_Get_library_version" })
sum("mpi_get_library_version", "The implementation's own version string",
  { "MPI_Get_version" })
sum("mpi_error_string", "The human-readable text of an MPI error code",
  { "MPI_Error_class", "MPI_SUCCESS" })
sum("mpi_error_class", "The error class an error code belongs to",
  { "MPI_Error_string" })
sum("mpi_wtick", "Resolution of MPI_Wtime, in seconds", { "MPI_Wtime" })

sum("mpi_comm_group", "The group of processes underlying a communicator",
  { "MPI_Group_rank", "MPI_Comm_create" })
sum("mpi_comm_create", "Create a communicator from a subgroup of an existing one",
  { "MPI_Comm_split", "MPI_Comm_group" })
sum("mpi_comm_split_type", "Split a communicator by a hardware property, such as shared memory",
  { "MPI_Comm_split", "MPI_Win_allocate_shared" })
sum("mpi_comm_compare", "Compare two communicators for identity, congruence or similarity",
  { "MPI_Comm_dup" })
sum("mpi_group_rank", "The calling process's rank within a group",
  { "MPI_Comm_group", "MPI_Comm_rank" })
sum("mpi_group_size", "Number of processes in a group", { "MPI_Comm_group" })
sum("mpi_group_incl", "Build a group from a list of ranks of an existing group",
  { "MPI_Group_excl", "MPI_Comm_create" })
sum("mpi_group_excl", "Build a group by removing a list of ranks from an existing group",
  { "MPI_Group_incl" })
sum("mpi_group_free", "Release a group handle", { "MPI_Comm_group" })
sum("mpi_op_create", "Register a user-defined reduction operation",
  { "MPI_Reduce", "MPI_Op_free" })
sum("mpi_op_free", "Release a user-defined reduction operation", { "MPI_Op_create" })

sum("mpi_cart_create", "Create a communicator with a Cartesian process topology",
  { "MPI_Cart_rank", "MPI_Cart_shift", "MPI_Dims_create" })
sum("mpi_cart_rank", "The rank owning a given set of Cartesian coordinates",
  { "MPI_Cart_coords", "MPI_Cart_create" })
sum("mpi_cart_coords", "The Cartesian coordinates of a given rank",
  { "MPI_Cart_rank", "MPI_Cart_create" })
sum("mpi_cart_shift", "The source and destination ranks for a shift along one Cartesian dimension",
  { "MPI_Sendrecv", "MPI_Cart_create" })
sum("mpi_cart_sub", "Split a Cartesian communicator into lower-dimensional sub-grids",
  { "MPI_Cart_create", "MPI_Comm_split" })
sum("mpi_dims_create", "Suggest a balanced factorisation of a process count into a grid",
  { "MPI_Cart_create" })

sum("mpi_alloc_mem", "Allocate memory MPI may be able to transfer faster",
  { "MPI_Free_mem", "MPI_Win_create" })
sum("mpi_free_mem", "Release memory obtained from MPI_Alloc_mem", { "MPI_Alloc_mem" })
sum("mpi_win_create", "Expose a local memory region as a one-sided access window",
  { "MPI_Win_fence", "MPI_Put", "MPI_Get" })
sum("mpi_win_fence", "Collective synchronisation of one-sided accesses to a window",
  { "MPI_Win_create", "MPI_Put" })
sum("mpi_win_free", "Release a one-sided window", { "MPI_Win_create" })
sum("mpi_put", "Write into another rank's window, one-sided",
  { "MPI_Get", "MPI_Win_fence" })
sum("mpi_get", "Read from another rank's window, one-sided",
  { "MPI_Put", "MPI_Win_fence" })
sum("mpi_accumulate", "Combine data into another rank's window with a reduction operation",
  { "MPI_Put", "MPI_Win_fence" })

sum("mpi_aint_add", "Add a byte displacement to an address, without integer overflow",
  { "MPI_Get_address", "MPI_Aint_diff" })
sum("mpi_aint_diff", "Difference of two addresses, without integer overflow",
  { "MPI_Get_address", "MPI_Aint_add" })
sum("mpi_sizeof", "Size in bytes of one element of a Fortran variable",
  { "MPI_Type_size", "MPI_Type_match_size" })
sum("mpi_pcontrol", "Hint to a profiling layer; the MPI library itself may ignore it")

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
--
-- `value` is NOT set here: gen-mpi.lua reads the installed `mpif*.h`, and a
-- hand-written number would go stale the day the MPI package changes. The two
-- sentinels have no value at all -- they are COMMON-block variables, which is
-- why `MPI_STATUS_IGNORE` cannot be used in an initialisation expression.

local function const(name, t)
  O[name] = O[name] or {}
  for k, v in pairs(t) do
    O[name][k] = v
  end
  O[name].standard = O[name].standard or S1
end

const("mpi_comm_world", {
  section = "Communicators",
  standard = S1,
})

const("mpi_comm_self", {
  summary = "The communicator containing only the calling process",
  description = "**MPI_COMM_SELF** is the predefined communicator whose group holds exactly\n" ..
    "one process: the caller. Its size is always 1 and the caller's rank in it is\n" ..
    "always 0.\n\n" ..
    "It is what a library uses when it must do something collective without\n" ..
    "involving anyone else -- attaching an error handler, allocating a window for\n" ..
    "purely local RMA, or registering an attribute whose destructor should fire at\n" ..
    "MPI_Finalize. Passing MPI_COMM_SELF where MPI_COMM_WORLD was meant is a\n" ..
    "deadlock, not an error: every rank waits alone.",
  example = "  call MPI_Comm_size(MPI_COMM_SELF, n, ierr)   ! n == 1, always",
  see_also = { "MPI_COMM_WORLD", "MPI_Comm_split" },
  section = "Communicators",
  standard = S1,
})

const("mpi_proc_null", {
  summary = "A rank that may be used as a source or destination and does nothing",
  description = "**MPI_PROC_NULL** is the null process. A send to it returns immediately and\n" ..
    "delivers nothing; a receive from it returns immediately, leaves the buffer\n" ..
    "untouched, and reports source MPI_PROC_NULL, tag MPI_ANY_TAG and count 0.\n\n" ..
    "That is what makes it valuable: the edges of a halo exchange need no special\n" ..
    "case. MPI_Cart_shift already returns MPI_PROC_NULL for a neighbour that falls\n" ..
    "off a non-periodic grid, so the same MPI_Sendrecv runs on interior and\n" ..
    "boundary ranks alike.",
  example = "  call MPI_Cart_shift(cart, 0, 1, left, right, ierr)\n" ..
    "  ! left or right may be MPI_PROC_NULL at the grid edge -- no branch needed\n" ..
    "  call MPI_Sendrecv(out, n, MPI_DOUBLE_PRECISION, right, 1, &\n" ..
    "                    in,  n, MPI_DOUBLE_PRECISION, left,  1, &\n" ..
    "                    cart, status, ierr)",
  see_also = { "MPI_Cart_shift", "MPI_ANY_SOURCE", "MPI_Sendrecv" },
  section = "Ranks",
  standard = S1,
})

const("mpi_status_ignore", {
  summary = "Pass instead of a status array when the status is not wanted",
  description = "**MPI_STATUS_IGNORE** tells MPI not to fill in a status, which saves the\n" ..
    "implementation the work of writing it.\n\n" ..
    "It is a COMMON-block variable, not a PARAMETER, so it cannot appear in an\n" ..
    "initialisation expression and it must be in scope -- in the F77 binding that\n" ..
    "means `include 'mpif.h'` in the same program unit. Use MPI_STATUSES_IGNORE for\n" ..
    "the array form taken by MPI_Waitall.",
  example = "  call MPI_Recv(buf, n, MPI_DOUBLE_PRECISION, src, tag, &\n" ..
    "                MPI_COMM_WORLD, MPI_STATUS_IGNORE, ierr)",
  see_also = { "MPI_Recv", "MPI_Wait", "MPI_STATUS_SIZE" },
  section = "Status",
  standard = S2,
})

const("mpi_in_place", {
  summary = "Pass as the send buffer of a collective to reduce in place",
  description = "**MPI_IN_PLACE** replaces the send buffer of a collective and asks MPI to\n" ..
    "take the input from, and leave the result in, the receive buffer. It removes\n" ..
    "the second array a naive MPI_Allreduce needs, which matters when the buffer is\n" ..
    "large.\n\n" ..
    "The rules differ per routine -- for MPI_Reduce only the root passes it, for\n" ..
    "MPI_Allreduce every rank does -- and passing it on the wrong side is undefined\n" ..
    "behaviour rather than an error. Like MPI_STATUS_IGNORE it is a COMMON-block\n" ..
    "variable, so it must be in scope.",
  example = "  ! every rank: total = sum over ranks of total\n" ..
    "  call MPI_Allreduce(MPI_IN_PLACE, total, 1, MPI_DOUBLE_PRECISION, &\n" ..
    "                     MPI_SUM, MPI_COMM_WORLD, ierr)",
  see_also = { "MPI_Allreduce", "MPI_Reduce", "MPI_Gather" },
  section = "Collectives",
  standard = S2,
})

const("mpi_success", { section = "Error codes", standard = S1 })

-- The only prose entry in the corpus that mixes a 4-space literal block into a
-- one-space hanging indent, so gen-mpi.lua's `dedent` correctly refuses to
-- touch it (it cannot tell an artifact from a deliberate literal). Re-authored
-- here as markdown -- a real fence -- which is what the rest of the registry
-- uses and what the float renders.
const("mpi_status_size", {
  section = "Status",
  standard = S1,
  description = "**MPI_STATUS_SIZE** is the extent of the INTEGER array that holds an MPI\n" ..
    "status in the Fortran binding. Every status variable is declared with it:\n\n" ..
    "```fortran\ninteger :: status(MPI_STATUS_SIZE)\n```\n\n" ..
    "and an array of statuses, for MPI_Waitall, is\n" ..
    "`INTEGER stats(MPI_STATUS_SIZE, n)` -- that order, which is easy to reverse.\n\n" ..
    "The array's fields are reached by the named indices MPI_SOURCE, MPI_TAG and\n" ..
    "MPI_ERROR; the remaining entries are opaque, and the received length is\n" ..
    "obtained through MPI_Get_count rather than by indexing.",
})
const("mpi_any_source", { section = "Ranks", standard = S1 })
const("mpi_any_tag", { section = "Tags", standard = S1 })
const("mpi_undefined", { section = "Sentinels", standard = S1 })
const("mpi_integer", { section = "Datatypes", standard = S1 })
const("mpi_double_precision", { section = "Datatypes", standard = S1 })
const("mpi_real", { section = "Datatypes", standard = S1 })
const("mpi_character", { section = "Datatypes", standard = S1 })
const("mpi_logical", { section = "Datatypes", standard = S1 })
const("mpi_complex", { section = "Datatypes", standard = S1 })
const("mpi_byte", { section = "Datatypes", standard = S1 })
const("mpi_packed", { section = "Datatypes", standard = S1 })
const("mpi_sum", { section = "Reduction operations", standard = S1 })
const("mpi_max", { section = "Reduction operations", standard = S1 })
const("mpi_min", { section = "Reduction operations", standard = S1 })
const("mpi_prod", { section = "Reduction operations", standard = S1 })
const("mpi_land", { section = "Reduction operations", standard = S1 })
const("mpi_lor", { section = "Reduction operations", standard = S1 })
const("mpi_maxloc", { section = "Reduction operations", standard = S1 })
const("mpi_minloc", { section = "Reduction operations", standard = S1 })
const("mpi_comm_null", { section = "Sentinels", standard = S1 })
const("mpi_request_null", { section = "Sentinels", standard = S1 })
const("mpi_source", { section = "Status", standard = S1 })
const("mpi_tag", { section = "Status", standard = S1 })
const("mpi_error", { section = "Status", standard = S1 })

-- Error classes. `ierror` is compared against these, so each gets the one line
-- that says what actually went wrong.
local function err(name, summary)
  O[name] = O[name] or {}
  O[name].summary = summary
  O[name].section = "Error codes"
  O[name].standard = O[name].standard or S1
  O[name].see_also = { "MPI_Error_string", "MPI_Error_class", "MPI_SUCCESS" }
end

err("mpi_err_access", "Permission denied on a file operation")
err("mpi_err_amode", "Invalid or contradictory access mode passed to MPI_File_open")
err("mpi_err_arg", "An argument was invalid in a way no other class describes")
err("mpi_err_assert", "Invalid assert argument to a one-sided synchronisation call")
err("mpi_err_bad_file", "Malformed file name")
err("mpi_err_base", "Invalid base address passed to a window or memory call")
err("mpi_err_buffer", "Invalid buffer pointer")
err("mpi_err_comm", "Invalid communicator")
err("mpi_err_conversion", "A user-defined data representation conversion function failed")
err("mpi_err_count", "Invalid count argument -- counts must be non-negative")
err("mpi_err_dims", "Invalid dimension argument to a topology call")
err("mpi_err_disp", "Invalid displacement argument in a one-sided call")
err("mpi_err_dup_datarep", "A data representation of that name is already registered")
err("mpi_err_file", "Invalid file handle")
err("mpi_err_file_exists", "The file already exists")
err("mpi_err_file_in_use", "The file is open by some other process")
err("mpi_err_group", "Invalid group")
err("mpi_err_in_status", "The real error is in the status objects, not in this code")
err("mpi_err_info", "Invalid info object")
err("mpi_err_info_key", "Info key too long, or otherwise invalid")
err("mpi_err_info_nokey", "The info object has no such key")
err("mpi_err_info_value", "Info value too long, or otherwise invalid")
err("mpi_err_intern", "An internal error in the MPI implementation")
err("mpi_err_io", "An I/O error occurred")
err("mpi_err_keyval", "Invalid attribute key")
err("mpi_err_lastcode", "The largest error code the implementation may return")
err("mpi_err_locktype", "Invalid lock type passed to MPI_Win_lock")
err("mpi_err_name", "Invalid service name in a name-publishing call")
err("mpi_err_no_mem", "MPI_Alloc_mem could not satisfy the request")
err("mpi_err_no_space", "The filesystem is out of space")
err("mpi_err_no_such_file", "The file does not exist")
err("mpi_err_not_same", "A collective argument differed between ranks")
err("mpi_err_op", "Invalid reduction operation")
err("mpi_err_other", "A known error with no more specific class")
err("mpi_err_pending", "The operation is still pending; not an error in itself")
err("mpi_err_port", "Invalid port name in a connect call")
err("mpi_err_quota", "A filesystem quota was exceeded")
err("mpi_err_rank", "Invalid rank for the given communicator")
err("mpi_err_read_only", "The file or filesystem is read-only")
err("mpi_err_request", "Invalid request handle")
err("mpi_err_rma_attach", "Memory could not be attached to a dynamic window")
err("mpi_err_rma_conflict", "Conflicting concurrent accesses to a window")
err("mpi_err_rma_flavor", "The call is not valid for this flavour of window")
err("mpi_err_rma_range", "The target of a one-sided access lies outside the window")
err("mpi_err_rma_shared", "Memory could not be shared between the ranks of the window")
err("mpi_err_rma_sync", "Wrong one-sided synchronisation call for the current epoch")
err("mpi_err_root", "Invalid root rank")
err("mpi_err_service", "Invalid service name in a name-publishing call")
err("mpi_err_size", "Invalid size argument in a one-sided call")
err("mpi_err_spawn", "A process could not be spawned")
err("mpi_err_tag", "Invalid tag -- tags must be non-negative and at most MPI_TAG_UB")
err("mpi_err_topology", "Invalid topology on the communicator")
err("mpi_err_truncate", "The message was longer than the receive buffer")
err("mpi_err_type", "Invalid datatype, or one that was never committed")
err("mpi_err_unknown", "An error of a class the implementation cannot name")
err("mpi_err_unsupported_datarep", "The requested data representation is not supported")
err("mpi_err_unsupported_operation", "The operation is not supported on this file or window")
err("mpi_err_win", "Invalid window handle")

-- ---------------------------------------------------------------------------
-- Modules
-- ---------------------------------------------------------------------------

O.mpi_f08 = {
  name = "mpi_f08",
  kind = "module",
  module = "mpi_f08",
  signature = "use mpi_f08",
  standard = S3,
  section = "Bindings",
  href = "https://www.open-mpi.org/doc/current/man3/MPI_T.3.php",
}

return O
