return {
  _meta = {
    generator = "snippets/gen-mpi.lua",
    install = "Open MPI 5.0.10",
    source = "~/miniconda3/include/mpi.mod",
    source_constants = "~/miniconda3/include/mpif*.h",
    source_f08 = "~/miniconda3/include/mpi_f08_interfaces.mod",
    source_version = "GFORTRAN module version '15' created from mpi-ignore-tkr.F90",
  },
  mpi_2complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "26",
  },
  mpi_2double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "27",
  },
  mpi_2double_precision = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2DOUBLE_PRECISION",
    section = "mpif-handles.h",
    type = "integer",
    value = "24",
  },
  mpi_2int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "52",
  },
  mpi_2integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2INTEGER",
    section = "mpif-handles.h",
    type = "integer",
    value = "25",
  },
  mpi_2real = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_2REAL",
    section = "mpif-handles.h",
    type = "integer",
    value = "23",
  },
  mpi_abort = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Abort** makes a best effort to terminate all processes in **comm**.\n" ..
      "It is the correct way to fail out of a parallel program: a plain STOP on one\n" ..
      "rank leaves the others blocked forever in whatever collective they were\n" ..
      "waiting on, which looks like a hang rather than an error.\n" ..
      "\n" ..
      "The standard permits aborting only **comm**, but most implementations abort\n" ..
      "the entire job whatever communicator is passed -- do not rely on the narrower\n" ..
      "behaviour.",
    example = "  if (ios /= 0) then\n" ..
      "     write(*,*) 'rank ', rank, ': cannot open input file'\n" ..
      "     call MPI_Abort(MPI_COMM_WORLD, 1, ierr)   ! not STOP\n" ..
      "  end if",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Abort.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Abort",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      errorcode = "Status returned to the invoking environment (the shell's exit status, typically).",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "Does not return. The job terminates with **errorcode**.",
    see_also = {
      "MPI_Finalize",
    },
    signature = "MPI_Abort(comm, errorcode, ierror)",
    standard = "MPI-1.0",
    summary = "Terminate every process in a communicator immediately",
  },
  mpi_accumulate = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), op as type(MPI_Op) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Accumulate.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Accumulate",
    see_also = {
      "MPI_Put",
      "MPI_Win_fence",
    },
    signature = "MPI_Accumulate(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, op, win, ierror)",
    standard = "MPI-2.0",
    summary = "Combine data into another rank's window with a reduction operation",
  },
  mpi_add_error_class = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Add_error_class.3.php",
    interface = {
      {
        intent = "out",
        name = "errorclass",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Add_error_class",
    signature = "MPI_Add_error_class(errorclass, ierror)",
    standard = "MPI-2.0",
  },
  mpi_add_error_code = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Add_error_code.3.php",
    interface = {
      {
        intent = "in",
        name = "errorclass",
        type = "integer",
      },
      {
        intent = "out",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Add_error_code",
    signature = "MPI_Add_error_code(errorclass, errorcode, ierror)",
    standard = "MPI-2.0",
  },
  mpi_add_error_string = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Add_error_string.3.php",
    interface = {
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "in",
        name = "string",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Add_error_string",
    signature = "MPI_Add_error_string(errorcode, string, ierror)",
    standard = "MPI-2.0",
  },
  mpi_address_kind = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ADDRESS_KIND",
    section = "mpif-config.h",
    type = "integer",
    value = "8",
  },
  mpi_aint = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_AINT",
    section = "mpif-handles.h",
    type = "integer",
    value = "66",
  },
  mpi_aint_add = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Aint_add.3.php",
    interface = {
      {
        name = "base",
        type = "integer(8)",
      },
      {
        name = "diff",
        type = "integer(8)",
      },
    },
    kind = "function",
    module = "mpi",
    name = "MPI_Aint_add",
    result_type = "integer(8)",
    see_also = {
      "MPI_Get_address",
      "MPI_Aint_diff",
    },
    signature = "MPI_Aint_add(base, diff)",
    standard = "MPI-3.1",
    summary = "Add a byte displacement to an address, without integer overflow",
  },
  mpi_aint_diff = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Aint_diff.3.php",
    interface = {
      {
        name = "addr1",
        type = "integer(8)",
      },
      {
        name = "addr2",
        type = "integer(8)",
      },
    },
    kind = "function",
    module = "mpi",
    name = "MPI_Aint_diff",
    result_type = "integer(8)",
    see_also = {
      "MPI_Get_address",
      "MPI_Aint_add",
    },
    signature = "MPI_Aint_diff(addr1, addr2)",
    standard = "MPI-3.1",
    summary = "Difference of two addresses, without integer overflow",
  },
  mpi_allgather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Allgather** is MPI_Gather followed by a broadcast of the result: every\n" ..
      "process ends up with every process's contribution, in rank order. There is no\n" ..
      "root, and every process needs the full-size receive buffer.\n" ..
      "\n" ..
      "Prefer it to gather-then-broadcast; the implementation has better algorithms\n" ..
      "available than the two calls written out.",
    example = "  call MPI_Allgather(nlocal, 1, MPI_INTEGER, &\n" ..
      "                     counts, 1, MPI_INTEGER, MPI_COMM_WORLD, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allgather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allgather",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      recvbuf = "Receive buffer on EVERY process, sized recvcount * nprocs.",
      recvcount = "Elements received from EACH process.",
      recvtype = "Datatype of the received elements.",
      sendbuf = "Data contributed by this process.",
      sendcount = "Number of elements this process sends.",
      sendtype = "Datatype of the sent elements.",
    },
    result = "Every process's **recvbuf** holds all contributions in rank order.",
    see_also = {
      "MPI_Gather",
      "MPI_Allreduce",
    },
    signature = "MPI_Allgather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Collect data from all processes onto all processes",
  },
  mpi_allgather_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allgather_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allgather_init",
    signature = "MPI_Allgather_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_allgatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allgatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allgatherv",
    see_also = {
      "MPI_Allgather",
      "MPI_Gatherv",
    },
    signature = "MPI_Allgatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Gather varying counts from every rank to every rank",
  },
  mpi_allgatherv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allgatherv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allgatherv_init",
    signature = "MPI_Allgatherv_init(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_alloc_mem = {
    binding_note = "mpi_f08 spells info as type(MPI_Info) and baseptr as type(C_ptr); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alloc_mem.3.php",
    interface = {
      {
        intent = "in",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "baseptr",
        type = "type(C_ptr)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alloc_mem",
    see_also = {
      "MPI_Free_mem",
      "MPI_Win_create",
    },
    signature = "MPI_Alloc_mem(size, info, baseptr, ierror)",
    standard = "MPI-2.0",
    summary = "Allocate memory MPI may be able to transfer faster",
  },
  mpi_allreduce = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Allreduce** performs a global reduction operation (sum, max, min, etc.) on data from all processes in a communicator and distributes the result to all processes. This is equivalent to an MPI_Reduce followed by an MPI_Bcast, but is typically more efficient. All processes contribute data and all processes receive the final result.",
    example = "program demo_mpi_allreduce\n" ..
      "  use mpi\n" ..
      "  implicit none\n" ..
      "  integer :: ierr, rank, nprocs\n" ..
      "  real(8) :: local_sum, global_sum\n" ..
      "  real(8) :: local_max, global_max\n" ..
      "  real(8) :: local_array(3), global_array(3)\n" ..
      "\n" ..
      "  ! Initialize MPI\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  ! Example 1: Sum of scalar values across all processes\n" ..
      "  local_sum = real(rank + 1, 8)  ! Each process has value rank+1\n" ..
      "  call MPI_Allreduce(local_sum, global_sum, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, MPI_COMM_WORLD, ierr)\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,F8.2)', 'Global sum: ', global_sum\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Example 2: Maximum value across all processes\n" ..
      "  local_max = real(rank * 10, 8)\n" ..
      "  call MPI_Allreduce(local_max, global_max, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_MAX, MPI_COMM_WORLD, ierr)\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,F8.2)', 'Global max: ', global_max\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Example 3: Element-wise reduction of arrays\n" ..
      "  local_array = [real(rank, 8), real(rank*2, 8), real(rank*3, 8)]\n" ..
      "  call MPI_Allreduce(local_array, global_array, 3, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, MPI_COMM_WORLD, ierr)\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,3F8.2)', 'Global array sum: ', global_array\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Example 4: In-place reduction (result overwrites sendbuf)\n" ..
      "  local_sum = real(rank + 1, 8)\n" ..
      "  call MPI_Allreduce(MPI_IN_PLACE, local_sum, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, MPI_COMM_WORLD, ierr)\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,F8.2)', 'In-place sum: ', local_sum\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "end program demo_mpi_allreduce",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allreduce.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allreduce",
    params = {
      comm = "MPI communicator defining the group of processes participating. Typically MPI_COMM_WORLD for all processes.",
      count = "Number of elements in `sendbuf` and `recvbuf`. Must be non-negative and identical on all processes.",
      datatype = "MPI datatype of elements. Common Fortran types: - MPI_INTEGER, MPI_REAL, MPI_DOUBLE_PRECISION - MPI_COMPLEX, MPI_DOUBLE_COMPLEX - MPI_LOGICAL, MPI_CHARACTER",
      ierror = "Integer error code. Returns MPI_SUCCESS (0) on successful completion.",
      op = "Reduction operation to perform. Predefined operations: - Arithmetic: MPI_SUM, MPI_PROD - Comparison: MPI_MAX, MPI_MIN - Logical: MPI_LAND, MPI_LOR, MPI_LXOR - Bitwise: MPI_BAND, MPI_BOR, MPI_BXOR - Location: MPI_MAXLOC, MPI_MINLOC",
      recvbuf = "Starting address of the receive buffer where the reduction result will be stored. Must be distinct from `sendbuf` unless using MPI_IN_PLACE.",
      sendbuf = "Starting address of the send buffer containing `count` elements of type `datatype`. Use MPI_IN_PLACE for in-place operations on intracommunicators.",
    },
    result = "On all processes, **recvbuf** contains the combined result of applying\n" ..
      "the reduction operation to the corresponding elements from all processes.\n" ..
      "Unlike MPI_Reduce, every process receives the same result. The operation\n" ..
      "is applied element-wise for arrays (when count > 1). This is equivalent\n" ..
      "to an MPI_Reduce followed by an MPI_Bcast but may be implemented more\n" ..
      "efficiently.",
    see_also = {
      "MPI_Reduce",
      "MPI_Bcast",
      "MPI_Scatter",
      "MPI_Gather",
      "MPI_Allgather",
      "MPI_Reduce_scatter",
      "MPI_Iallreduce",
    },
    signature = "MPI_Allreduce(sendbuf, recvbuf, count, datatype, op, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Combines values from all processes and distributes the result back to all processes",
  },
  mpi_allreduce_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Allreduce_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Allreduce_init",
    signature = "MPI_Allreduce_init(sendbuf, recvbuf, count, datatype, op, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_alltoall = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Alltoall** performs a complete exchange: rank i sends its j-th block\n" ..
      "to rank j and receives rank j's i-th block. It is effectively a distributed\n" ..
      "transpose, and the standard step of a parallel FFT.\n" ..
      "\n" ..
      "Both buffers must hold count * nprocs elements. It moves more data than any\n" ..
      "other collective; on a large job it is usually the scaling bottleneck.",
    example = "  call MPI_Alltoall(sbuf, n, MPI_DOUBLE_PRECISION, &\n" ..
      "                    rbuf, n, MPI_DOUBLE_PRECISION, MPI_COMM_WORLD, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoall.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoall",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      recvbuf = "Receive buffer, sized recvcount * nprocs.",
      recvcount = "Elements received from EACH process.",
      recvtype = "Datatype of the received elements.",
      sendbuf = "Blocks to send, one per destination rank, sized sendcount * nprocs.",
      sendcount = "Elements sent to EACH process.",
      sendtype = "Datatype of the sent elements.",
    },
    result = "Block j of **recvbuf** holds the data rank j sent to this process.",
    see_also = {
      "MPI_Allgather",
      "MPI_Alltoallv",
    },
    signature = "MPI_Alltoall(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Every process sends a distinct block to every process",
  },
  mpi_alltoall_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoall_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoall_init",
    signature = "MPI_Alltoall_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_alltoallv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoallv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoallv",
    see_also = {
      "MPI_Alltoall",
      "MPI_Scatterv",
    },
    signature = "MPI_Alltoallv(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Exchange a varying number of elements between every pair of ranks",
  },
  mpi_alltoallv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoallv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoallv_init",
    signature = "MPI_Alltoallv_init(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_alltoallw = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoallw.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoallw",
    signature = "MPI_Alltoallw(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, ierror)",
    standard = "MPI-2.0",
  },
  mpi_alltoallw_init = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Alltoallw_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Alltoallw_init",
    signature = "MPI_Alltoallw_init(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_any_source = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_ANY_SOURCE** used as the source of a receive matches a message from\n" ..
      "any rank. The actual sender is then read from status(MPI_SOURCE).\n" ..
      "\n" ..
      "It costs determinism: the order in which messages are taken now depends on\n" ..
      "arrival, so a program using it is not reproducible run to run. That matters\n" ..
      "for anything accumulating floating-point values in receive order. It also\n" ..
      "makes probe-then-receive racy unless the receive names status(MPI_SOURCE)\n" ..
      "rather than the wildcard a second time.",
    example = "  call MPI_Recv(buf, LPMX, MPI_DOUBLE_PRECISION, MPI_ANY_SOURCE, &\n" ..
      "                tag, MPI_COMM_WORLD, status, ierr)\n" ..
      "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, nrecv, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ANY_SOURCE",
    section = "Ranks",
    see_also = {
      "MPI_SOURCE",
      "MPI_ANY_TAG",
      "MPI_Probe",
    },
    standard = "MPI-1.0",
    summary = "Wildcard: receive from any sender",
    type = "integer",
    value = "-1",
  },
  mpi_any_tag = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_ANY_TAG** as the tag of a receive matches a message with any tag; the\n" ..
      "real tag is then status(MPI_TAG).\n" ..
      "\n" ..
      "As with MPI_ANY_SOURCE it removes ordering guarantees, and it is riskier in\n" ..
      "library code, where it can swallow messages belonging to the application.\n" ..
      "A duplicated communicator (MPI_Comm_dup) is the fix.",
    example = "  call MPI_Recv(buf, n, MPI_INTEGER, isrc, MPI_ANY_TAG, &\n" ..
      "                MPI_COMM_WORLD, status, ierr)\n" ..
      "  itag = status(MPI_TAG)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ANY_TAG",
    section = "Tags",
    see_also = {
      "MPI_ANY_SOURCE",
      "MPI_Comm_dup",
    },
    standard = "MPI-1.0",
    summary = "Wildcard: receive a message with any tag",
    type = "integer",
    value = "-1",
  },
  mpi_appnum = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_APPNUM",
    section = "mpif-constants.h",
    type = "integer",
    value = "4",
  },
  mpi_argv_null = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ARGV_NULL",
    section = "mpif-sentinels.h",
    type = "character",
  },
  mpi_argvs_null = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ARGVS_NULL",
    section = "mpif-sentinels.h",
    type = "character",
  },
  mpi_async_protects_nonblocking = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ASYNC_PROTECTS_NONBLOCKING",
    section = "mpif-config.h",
    type = "logical",
    value = ".false.",
  },
  mpi_band = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BAND",
    section = "mpif-handles.h",
    type = "integer",
    value = "6",
  },
  mpi_barrier = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Barrier** blocks the calling process until all processes in the\n" ..
      "communicator have called it. It is the only purely synchronizing collective:\n" ..
      "no data moves.\n" ..
      "\n" ..
      "It is easy to over-use. A barrier is genuinely needed to order operations\n" ..
      "against something outside MPI's knowledge -- writing a shared file, reading a\n" ..
      "wall clock, timing a region -- but MPI's own collectives (MPI_Bcast,\n" ..
      "MPI_Reduce, MPI_Allreduce) already synchronize as much as their semantics\n" ..
      "require, so a barrier placed next to one is usually dead cost.\n" ..
      "\n" ..
      "A barrier that only SOME processes reach deadlocks the job. That is the usual\n" ..
      "outcome of putting one inside a conditional branch.",
    example = "  ! Order stdout against the file system, which MPI knows nothing about\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  if (rank == 0) then\n" ..
      "     open(unit=10, file='results.dat', status='replace')\n" ..
      "     write(10,*) total\n" ..
      "     close(10)\n" ..
      "  end if\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  ! Timing a region: without the barrier, t0 measures skew, not work\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  t0 = MPI_Wtime()\n" ..
      "  call heavy_work()\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  t1 = MPI_Wtime()",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Barrier.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Barrier",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "Returns once every process in **comm** has entered the call. No buffer\n" ..
      "is read or written.",
    see_also = {
      "MPI_Wtime",
      "MPI_Bcast",
      "MPI_Allreduce",
    },
    signature = "MPI_Barrier(comm, ierror)",
    standard = "MPI-1.0",
    summary = "Block until every process in a communicator has reached this call",
  },
  mpi_barrier_init = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Barrier_init.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Barrier_init",
    signature = "MPI_Barrier_init(comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_bcast = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Bcast** broadcasts a message from the process with rank **root** to all\n" ..
      "other processes in the group, including itself. After the call, all processes\n" ..
      "in the communicator have identical copies of the buffer data. This is a\n" ..
      "collective operation that must be called by all processes in the communicator.",
    example = "program demo_mpi_bcast\n" ..
      "  use mpi\n" ..
      "  implicit none\n" ..
      "\n" ..
      "  integer :: ierr, rank, nprocs\n" ..
      "  integer :: root\n" ..
      "  real(8) :: value\n" ..
      "  real(8), dimension(4) :: array\n" ..
      "\n" ..
      "  ! Initialize MPI\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  root = 0\n" ..
      "\n" ..
      "  ! Example 1: Broadcast a scalar\n" ..
      "  if (rank == root) then\n" ..
      "    value = 3.14159265358979d0\n" ..
      "    print '(A,I2,A,F12.8)', 'Process ', rank, ' (root) sending value: ', value\n" ..
      "  else\n" ..
      "    value = 0.0d0\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Bcast(value, 1, MPI_DOUBLE_PRECISION, root, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  print '(A,I2,A,F12.8)', 'Process ', rank, ' received value: ', value\n" ..
      "\n" ..
      "  ! Example 2: Broadcast an array\n" ..
      "  if (rank == root) then\n" ..
      "    array = [1.0d0, 2.0d0, 3.0d0, 4.0d0]\n" ..
      "    print '(A,I2,A)', 'Process ', rank, ' (root) broadcasting array'\n" ..
      "  else\n" ..
      "    array = 0.0d0\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Bcast(array, 4, MPI_DOUBLE_PRECISION, root, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  print '(A,I2,A,4F8.2)', 'Process ', rank, ' array: ', array\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "end program demo_mpi_bcast",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Bcast.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buffer",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Bcast",
    params = {
      buffer = "Starting address of the data buffer. On the root process, this contains the data to be broadcast. On all other processes, this is where the received data will be stored.",
      comm = "MPI communicator defining the process group. Typically MPI_COMM_WORLD for all processes, or a custom communicator for subgroups.",
      count = "Number of elements in the buffer. Must be non-negative and identical on all processes.",
      datatype = "MPI datatype of each buffer element. Common values include: MPI_INTEGER, MPI_REAL, MPI_DOUBLE_PRECISION, MPI_COMPLEX, MPI_LOGICAL, MPI_CHARACTER. Must match on all processes.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on successful completion, or an MPI error code on failure.",
      root = "Rank of the process sending the broadcast (0 to comm_size-1). Must be identical on all processes in the communicator.",
    },
    result = "After the call completes, all processes in the communicator have\n" ..
      "identical copies of the data that was in the root process's buffer.\n" ..
      "The buffer on the root process is unchanged; the buffers on all other\n" ..
      "processes contain the broadcast data. This is a collective operation\n" ..
      "that synchronizes all participating processes.",
    see_also = {
      "MPI_Ibcast",
      "MPI_Scatter",
      "MPI_Gather",
      "MPI_Allgather",
      "MPI_Reduce",
      "MPI_Allreduce",
      "MPI_Comm_rank",
      "MPI_Comm_size",
    },
    signature = "MPI_Bcast(buffer, count, datatype, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Broadcast a message from root to all processes in a communicator",
  },
  mpi_bcast_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Bcast_init.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buffer",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Bcast_init",
    signature = "MPI_Bcast_init(buffer, count, datatype, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_bor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BOR",
    section = "mpif-handles.h",
    type = "integer",
    value = "8",
  },
  mpi_bottom = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BOTTOM",
    section = "mpif-sentinels.h",
    type = "integer",
  },
  mpi_bsend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Bsend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Bsend",
    see_also = {
      "MPI_Send",
      "MPI_Buffer_attach",
    },
    signature = "MPI_Bsend(buf, count, datatype, dest, tag, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Buffered send: copies the message into a user-supplied buffer and returns",
  },
  mpi_bsend_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Bsend_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Bsend_init",
    signature = "MPI_Bsend_init(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_bsend_overhead = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BSEND_OVERHEAD",
    section = "mpif-constants.h",
    type = "integer",
    value = "128",
  },
  mpi_buffer_attach = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Buffer_attach.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buffer",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Buffer_attach",
    signature = "MPI_Buffer_attach(buffer, size, ierror)",
    standard = "MPI-1.0",
  },
  mpi_buffer_detach = {
    binding_note = "mpi_f08 spells buffer_addr as type(C_ptr); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Buffer_detach.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buffer",
        type = "<any type>",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Buffer_detach",
    signature = "MPI_Buffer_detach(buffer, size, ierror)",
    standard = "MPI-1.0",
  },
  mpi_bxor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BXOR",
    section = "mpif-handles.h",
    type = "integer",
    value = "10",
  },
  mpi_byte = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_BYTE** transfers raw bytes with no interpretation and no conversion.\n" ..
      "\n" ..
      "That last point is the catch: MPI performs representation conversion in a\n" ..
      "heterogeneous job for typed data, and skips it for MPI_BYTE. On a uniform\n" ..
      "cluster it is a convenient way to move a mixed record; across differing\n" ..
      "architectures it corrupts anything but text.",
    example = "  call MPI_Send(record, storage_size(record)/8, MPI_BYTE, &\n" ..
      "                dest, 1, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_BYTE",
    section = "Datatypes",
    see_also = {
      "MPI_Type_contiguous",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for an uninterpreted byte",
    type = "integer",
    value = "1",
  },
  mpi_c_bool = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_C_BOOL",
    section = "mpif-handles.h",
    type = "integer",
    value = "68",
  },
  mpi_c_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_C_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "69",
  },
  mpi_c_double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_C_DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "70",
  },
  mpi_c_float_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_C_FLOAT_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "69",
  },
  mpi_c_long_double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_C_LONG_DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "71",
  },
  mpi_cancel = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cancel.3.php",
    interface = {
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cancel",
    see_also = {
      "MPI_Request_free",
      "MPI_Test_cancelled",
    },
    signature = "MPI_Cancel(request, ierror)",
    standard = "MPI-1.0",
    summary = "Ask to cancel a pending nonblocking operation",
  },
  mpi_cart = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CART",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_cart_coords = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_coords.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxdims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "coords",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_coords",
    see_also = {
      "MPI_Cart_rank",
      "MPI_Cart_create",
    },
    signature = "MPI_Cart_coords(comm, rank, maxdims, coords, ierror)",
    standard = "MPI-1.0",
    summary = "The Cartesian coordinates of a given rank",
  },
  mpi_cart_create = {
    binding_note = "mpi_f08 spells comm_old as type(MPI_Comm) and comm_cart as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_create.3.php",
    interface = {
      {
        intent = "in",
        name = "old_comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "ndims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "periods",
        type = "logical",
      },
      {
        intent = "in",
        name = "reorder",
        type = "logical",
      },
      {
        intent = "out",
        name = "comm_cart",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_create",
    see_also = {
      "MPI_Cart_rank",
      "MPI_Cart_shift",
      "MPI_Dims_create",
    },
    signature = "MPI_Cart_create(old_comm, ndims, dims, periods, reorder, comm_cart, ierror)",
    standard = "MPI-1.0",
    summary = "Create a communicator with a Cartesian process topology",
  },
  mpi_cart_get = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_get.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxdims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "dims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "periods",
        type = "logical",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "coords",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_get",
    signature = "MPI_Cart_get(comm, maxdims, dims, periods, coords, ierror)",
    standard = "MPI-1.0",
  },
  mpi_cart_map = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_map.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "ndims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "periods",
        type = "logical",
      },
      {
        intent = "out",
        name = "newrank",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_map",
    signature = "MPI_Cart_map(comm, ndims, dims, periods, newrank, ierror)",
    standard = "MPI-1.0",
  },
  mpi_cart_rank = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_rank.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "coords",
        type = "integer",
      },
      {
        intent = "out",
        name = "rank",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_rank",
    see_also = {
      "MPI_Cart_coords",
      "MPI_Cart_create",
    },
    signature = "MPI_Cart_rank(comm, coords, rank, ierror)",
    standard = "MPI-1.0",
    summary = "The rank owning a given set of Cartesian coordinates",
  },
  mpi_cart_shift = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_shift.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "direction",
        type = "integer",
      },
      {
        intent = "in",
        name = "disp",
        type = "integer",
      },
      {
        intent = "out",
        name = "rank_source",
        type = "integer",
      },
      {
        intent = "out",
        name = "rank_dest",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_shift",
    see_also = {
      "MPI_Sendrecv",
      "MPI_Cart_create",
    },
    signature = "MPI_Cart_shift(comm, direction, disp, rank_source, rank_dest, ierror)",
    standard = "MPI-1.0",
    summary = "The source and destination ranks for a shift along one Cartesian dimension",
  },
  mpi_cart_sub = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cart_sub.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "remain_dims",
        type = "logical",
      },
      {
        intent = "out",
        name = "new_comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cart_sub",
    see_also = {
      "MPI_Cart_create",
      "MPI_Comm_split",
    },
    signature = "MPI_Cart_sub(comm, remain_dims, new_comm, ierror)",
    standard = "MPI-1.0",
    summary = "Split a Cartesian communicator into lower-dimensional sub-grids",
  },
  mpi_cartdim_get = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Cartdim_get.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ndims",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Cartdim_get",
    signature = "MPI_Cartdim_get(comm, ndims, ierror)",
    standard = "MPI-1.0",
  },
  mpi_char = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CHAR",
    section = "mpif-handles.h",
    type = "integer",
    value = "34",
  },
  mpi_character = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_CHARACTER** is the datatype handle for a single Fortran CHARACTER.\n" ..
      "The count is the number of characters, so a `CHARACTER(LEN=80)` variable is\n" ..
      "sent with count 80, not 1.",
    example = "  character(len=80) :: drname\n" ..
      "  call MPI_Bcast(drname, 80, MPI_CHARACTER, 0, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CHARACTER",
    section = "Datatypes",
    see_also = {
      "MPI_Bcast",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for Fortran CHARACTER",
    type = "integer",
    value = "5",
  },
  mpi_close_port = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Close_port.3.php",
    interface = {
      {
        intent = "in",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Close_port",
    signature = "MPI_Close_port(port_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_combiner_contiguous = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_CONTIGUOUS",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_combiner_darray = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_DARRAY",
    section = "mpif-constants.h",
    type = "integer",
    value = "13",
  },
  mpi_combiner_dup = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_DUP",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_combiner_f90_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_F90_COMPLEX",
    section = "mpif-constants.h",
    type = "integer",
    value = "15",
  },
  mpi_combiner_f90_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_F90_INTEGER",
    section = "mpif-constants.h",
    type = "integer",
    value = "16",
  },
  mpi_combiner_f90_real = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_F90_REAL",
    section = "mpif-constants.h",
    type = "integer",
    value = "14",
  },
  mpi_combiner_hindexed = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_HINDEXED",
    section = "mpif-constants.h",
    type = "integer",
    value = "8",
  },
  mpi_combiner_hindexed_block = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_HINDEXED_BLOCK",
    section = "mpif-constants.h",
    type = "integer",
    value = "18",
  },
  mpi_combiner_hindexed_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_HINDEXED_INTEGER",
    section = "mpif-constants.h",
    type = "integer",
    value = "7",
  },
  mpi_combiner_hvector = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_HVECTOR",
    section = "mpif-constants.h",
    type = "integer",
    value = "5",
  },
  mpi_combiner_hvector_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_HVECTOR_INTEGER",
    section = "mpif-constants.h",
    type = "integer",
    value = "4",
  },
  mpi_combiner_indexed = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_INDEXED",
    section = "mpif-constants.h",
    type = "integer",
    value = "6",
  },
  mpi_combiner_indexed_block = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_INDEXED_BLOCK",
    section = "mpif-constants.h",
    type = "integer",
    value = "9",
  },
  mpi_combiner_named = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_NAMED",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_combiner_resized = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_RESIZED",
    section = "mpif-constants.h",
    type = "integer",
    value = "17",
  },
  mpi_combiner_struct = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_STRUCT",
    section = "mpif-constants.h",
    type = "integer",
    value = "11",
  },
  mpi_combiner_struct_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_STRUCT_INTEGER",
    section = "mpif-constants.h",
    type = "integer",
    value = "10",
  },
  mpi_combiner_subarray = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_SUBARRAY",
    section = "mpif-constants.h",
    type = "integer",
    value = "12",
  },
  mpi_combiner_vector = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMBINER_VECTOR",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_comm_accept = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_accept.3.php",
    interface = {
      {
        intent = "in",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_accept",
    signature = "MPI_Comm_accept(port_name, info, root, comm, newcomm, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_call_errhandler = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_call_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_call_errhandler",
    signature = "MPI_Comm_call_errhandler(comm, errorcode, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_compare = {
    binding_note = "mpi_f08 spells comm1 as type(MPI_Comm) and comm2 as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_compare.3.php",
    interface = {
      {
        intent = "in",
        name = "comm1",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm2",
        type = "integer",
      },
      {
        intent = "out",
        name = "result",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_compare",
    see_also = {
      "MPI_Comm_dup",
    },
    signature = "MPI_Comm_compare(comm1, comm2, result, ierror)",
    standard = "MPI-1.0",
    summary = "Compare two communicators for identity, congruence or similarity",
  },
  mpi_comm_connect = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_connect.3.php",
    interface = {
      {
        intent = "in",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_connect",
    signature = "MPI_Comm_connect(port_name, info, root, comm, newcomm, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_create = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), group as type(MPI_Group) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_create.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_create",
    see_also = {
      "MPI_Comm_split",
      "MPI_Comm_group",
    },
    signature = "MPI_Comm_create(comm, group, newcomm, ierror)",
    standard = "MPI-1.0",
    summary = "Create a communicator from a subgroup of an existing one",
  },
  mpi_comm_create_errhandler = {
    binding_note = "mpi_f08 spells errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_create_errhandler.3.php",
    interface = {
      {
        name = "function",
        type = "external",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_create_errhandler",
    signature = "MPI_Comm_create_errhandler(function, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_create_group = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), group as type(MPI_Group) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_create_group.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_create_group",
    signature = "MPI_Comm_create_group(comm, group, tag, newcomm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_comm_create_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_create_keyval.3.php",
    interface = {
      {
        name = "comm_copy_attr_fn",
        type = "external",
      },
      {
        name = "comm_delete_attr_fn",
        type = "external",
      },
      {
        intent = "out",
        name = "comm_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_create_keyval",
    signature = "MPI_Comm_create_keyval(comm_copy_attr_fn, comm_delete_attr_fn, comm_keyval, extra_state, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_delete_attr = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_delete_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_delete_attr",
    signature = "MPI_Comm_delete_attr(comm, comm_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_disconnect = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_disconnect.3.php",
    interface = {
      {
        intent = "inout",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_disconnect",
    signature = "MPI_Comm_disconnect(comm, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_dup = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Comm_dup** makes a communicator with the same processes and ranks but\n" ..
      "a distinct communication context, so its messages can never match those on\n" ..
      "the original.\n" ..
      "\n" ..
      "That is what library code needs: a library that communicates on\n" ..
      "MPI_COMM_WORLD can have its messages intercepted by the application's own\n" ..
      "receives, especially where MPI_ANY_TAG is used. Duplicating at initialization\n" ..
      "makes the two message spaces disjoint.",
    example = "  ! Give the solver its own message space\n" ..
      "  call MPI_Comm_dup(MPI_COMM_WORLD, solver_comm, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_dup.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_dup",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      newcomm = "Returns the duplicate.",
    },
    result = "**newcomm** has the same group as **comm** and an isolated message space.",
    see_also = {
      "MPI_Comm_split",
      "MPI_Comm_free",
    },
    signature = "MPI_Comm_dup(comm, newcomm, ierror)",
    standard = "MPI-1.0",
    summary = "Duplicate a communicator",
  },
  mpi_comm_dup_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_COMM_DUP_FN.3.php",
    interface = {
      {
        name = "oldcomm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_COMM_DUP_FN",
    signature = "MPI_COMM_DUP_FN(oldcomm, comm_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_comm_dup_with_info = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), info as type(MPI_Info) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_dup_with_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_dup_with_info",
    signature = "MPI_Comm_dup_with_info(comm, info, newcomm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_comm_free = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Comm_free** marks a communicator for deallocation; it is actually\n" ..
      "released once pending operations on it finish, and the handle is set to\n" ..
      "MPI_COMM_NULL.\n" ..
      "\n" ..
      "It is collective, so every member must call it. Predefined communicators such\n" ..
      "as MPI_COMM_WORLD must not be freed.",
    example = "  call MPI_Comm_free(row_comm, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_free",
    params = {
      comm = "The communicator to free. Set to MPI_COMM_NULL on return.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "The communicator is released and the handle nulled.",
    see_also = {
      "MPI_Comm_split",
      "MPI_Comm_dup",
    },
    signature = "MPI_Comm_free(comm, ierror)",
    standard = "MPI-1.0",
    summary = "Release a communicator",
  },
  mpi_comm_free_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_free_keyval.3.php",
    interface = {
      {
        intent = "inout",
        name = "comm_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_free_keyval",
    signature = "MPI_Comm_free_keyval(comm_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_get_attr = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_get_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "attribute_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_get_attr",
    signature = "MPI_Comm_get_attr(comm, comm_keyval, attribute_val, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_get_errhandler = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_get_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "erhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_get_errhandler",
    signature = "MPI_Comm_get_errhandler(comm, erhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_get_info = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and info_used as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_get_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "info_used",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_get_info",
    signature = "MPI_Comm_get_info(comm, info_used, ierror)",
    standard = "MPI-3.0",
  },
  mpi_comm_get_name = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_get_name.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "comm_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_get_name",
    signature = "MPI_Comm_get_name(comm, comm_name, resultlen, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_get_parent = {
    binding_note = "mpi_f08 spells parent as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_get_parent.3.php",
    interface = {
      {
        intent = "out",
        name = "parent",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_get_parent",
    signature = "MPI_Comm_get_parent(parent, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_group = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_group.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_group",
    see_also = {
      "MPI_Group_rank",
      "MPI_Comm_create",
    },
    signature = "MPI_Comm_group(comm, group, ierror)",
    standard = "MPI-1.0",
    summary = "The group of processes underlying a communicator",
  },
  mpi_comm_idup = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), newcomm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_idup.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_idup",
    signature = "MPI_Comm_idup(comm, newcomm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_comm_idup_with_info = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), info as type(MPI_Info), newcomm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_idup_with_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_idup_with_info",
    signature = "MPI_Comm_idup_with_info(comm, info, newcomm, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_comm_join = {
    binding_note = "mpi_f08 spells intercomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_join.3.php",
    interface = {
      {
        intent = "in",
        name = "fd",
        type = "integer",
      },
      {
        intent = "out",
        name = "intercomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_join",
    signature = "MPI_Comm_join(fd, intercomm, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_COMM_NULL** is the value a communicator handle takes when it names no\n" ..
      "communicator: returned by MPI_Comm_split to a process that passed\n" ..
      "MPI_UNDEFINED as its colour, and left in a handle by MPI_Comm_free.\n" ..
      "\n" ..
      "Passing it to a communication routine is an error, so a rank excluded by a\n" ..
      "split must be guarded before it uses the result.",
    example = "  call MPI_Comm_split(MPI_COMM_WORLD, colour, rank, sub, ierr)\n" ..
      "  if (sub /= MPI_COMM_NULL) then\n" ..
      "     call MPI_Comm_rank(sub, subrank, ierr)\n" ..
      "  end if",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_NULL",
    section = "Sentinels",
    see_also = {
      "MPI_Comm_split",
      "MPI_Comm_free",
    },
    standard = "MPI-1.0",
    summary = "The null communicator handle",
    type = "integer",
    value = "2",
  },
  mpi_comm_null_copy_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_COMM_NULL_COPY_FN.3.php",
    interface = {
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_COMM_NULL_COPY_FN",
    signature = "MPI_COMM_NULL_COPY_FN(comm, comm_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_comm_null_delete_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_COMM_NULL_DELETE_FN.3.php",
    interface = {
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_COMM_NULL_DELETE_FN",
    signature = "MPI_COMM_NULL_DELETE_FN(comm, comm_keyval, attribute_val_out, extra_state, ierr)",
    standard = "MPI-2.0",
  },
  mpi_comm_rank = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Comm_rank** returns the calling process's index within **comm**,\n" ..
      "counting from ZERO. Together with MPI_Comm_size it is how a process discovers\n" ..
      "which part of the work is its own.\n" ..
      "\n" ..
      "The rank is meaningful only relative to the communicator it came from. A rank\n" ..
      "obtained from MPI_COMM_WORLD must not be used as a destination in a\n" ..
      "sub-communicator.",
    example = "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  ! Split a loop across ranks\n" ..
      "  my_lo = 1 + (rank * n) / nprocs\n" ..
      "  my_hi = ((rank + 1) * n) / nprocs",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_rank.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "rank",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_rank",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      rank = "Returns the calling process's rank, 0 to size-1.",
    },
    result = "**rank** holds the calling process's zero-based index in **comm**.",
    see_also = {
      "MPI_Comm_size",
      "MPI_COMM_WORLD",
    },
    signature = "MPI_Comm_rank(comm, rank, ierror)",
    standard = "MPI-1.0",
    summary = "Get the calling process's rank within a communicator",
  },
  mpi_comm_remote_group = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_remote_group.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_remote_group",
    signature = "MPI_Comm_remote_group(comm, group, ierror)",
    standard = "MPI-1.0",
  },
  mpi_comm_remote_size = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_remote_size.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_remote_size",
    signature = "MPI_Comm_remote_size(comm, size, ierror)",
    standard = "MPI-1.0",
  },
  mpi_comm_self = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_COMM_SELF** is the predefined communicator whose group holds exactly\n" ..
      "one process: the caller. Its size is always 1 and the caller's rank in it is\n" ..
      "always 0.\n" ..
      "\n" ..
      "It is what a library uses when it must do something collective without\n" ..
      "involving anyone else -- attaching an error handler, allocating a window for\n" ..
      "purely local RMA, or registering an attribute whose destructor should fire at\n" ..
      "MPI_Finalize. Passing MPI_COMM_SELF where MPI_COMM_WORLD was meant is a\n" ..
      "deadlock, not an error: every rank waits alone.",
    example = "  call MPI_Comm_size(MPI_COMM_SELF, n, ierr)   ! n == 1, always",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_SELF",
    section = "Communicators",
    see_also = {
      "MPI_COMM_WORLD",
      "MPI_Comm_split",
    },
    standard = "MPI-1.0",
    summary = "The communicator containing only the calling process",
    type = "integer",
    value = "1",
  },
  mpi_comm_set_attr = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_set_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "attribute_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_set_attr",
    signature = "MPI_Comm_set_attr(comm, comm_keyval, attribute_val, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_set_errhandler = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_set_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_set_errhandler",
    signature = "MPI_Comm_set_errhandler(comm, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_set_info = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_set_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_set_info",
    signature = "MPI_Comm_set_info(comm, info, ierror)",
    standard = "MPI-3.0",
  },
  mpi_comm_set_name = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_set_name.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_set_name",
    signature = "MPI_Comm_set_name(comm, comm_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_size = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Comm_size** returns how many processes belong to **comm**. For\n" ..
      "MPI_COMM_WORLD that is the size of the whole job, as launched by mpirun -n.\n" ..
      "\n" ..
      "Note the off-by-one that this invites: **size** is a count, but ranks are\n" ..
      "zero-based, so the last rank is size-1.",
    example = "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "  if (rank == nprocs - 1) then     ! NOT nprocs\n" ..
      "     print *, 'I am the last rank'\n" ..
      "  end if",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_size.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_size",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      size = "Returns the number of processes in **comm**.",
    },
    result = "**size** holds the number of processes in the communicator.",
    see_also = {
      "MPI_Comm_rank",
      "MPI_COMM_WORLD",
    },
    signature = "MPI_Comm_size(comm, size, ierror)",
    standard = "MPI-1.0",
    summary = "Get the number of processes in a communicator",
  },
  mpi_comm_spawn = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm) and intercomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_spawn.3.php",
    interface = {
      {
        intent = "in",
        name = "command",
        type = "character(len=*)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "argv",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "maxprocs",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "intercomm",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_errcodes",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_spawn",
    signature = "MPI_Comm_spawn(command, argv, maxprocs, info, root, comm, intercomm, array_of_errcodes, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_spawn_multiple = {
    binding_note = "mpi_f08 spells array_of_info as type(MPI_Info), comm as type(MPI_Comm) and intercomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_spawn_multiple.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_commands",
        type = "character(len=*)",
      },
      {
        dim = "(*, *)",
        intent = "in",
        name = "array_of_argv",
        type = "character(len=*)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_maxprocs",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_info",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "intercomm",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_errcodes",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_spawn_multiple",
    signature = "MPI_Comm_spawn_multiple(count, array_of_commands, array_of_argv, array_of_maxprocs, array_of_info, root, comm, intercomm, array_of_errcodes, ierror)",
    standard = "MPI-2.0",
  },
  mpi_comm_split = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Comm_split** partitions **comm**: every process supplies a **color**,\n" ..
      "and those sharing a colour end up in the same new communicator, ordered by\n" ..
      "**key**. It is the standard way to build row and column communicators for a\n" ..
      "process grid.\n" ..
      "\n" ..
      "A process passing MPI_UNDEFINED gets MPI_COMM_NULL and is in no new group --\n" ..
      "useful for excluding ranks, and a source of crashes if the result is then\n" ..
      "used unguarded. Note that ranks in **newcomm** are renumbered from zero.",
    example = "  ! One communicator per node-row of a 2-D decomposition\n" ..
      "  call MPI_Comm_split(MPI_COMM_WORLD, myrow, mycol, row_comm, ierr)\n" ..
      "  call MPI_Comm_rank(row_comm, row_rank, ierr)     ! renumbered",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_split.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "color",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_split",
    params = {
      color = "Subgroup selector; equal colours share a communicator. MPI_UNDEFINED to belong to none.",
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      key = "Controls rank ordering within the new communicator; ties break by rank in **comm**.",
      newcomm = "Returns the new communicator, or MPI_COMM_NULL.",
    },
    result = "**newcomm** is the caller's new communicator, with ranks numbered afresh.",
    see_also = {
      "MPI_Comm_dup",
      "MPI_Comm_free",
      "MPI_COMM_NULL",
    },
    signature = "MPI_Comm_split(comm, color, key, newcomm, ierror)",
    standard = "MPI-1.0",
    summary = "Partition a communicator into sub-communicators",
  },
  mpi_comm_split_type = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), info as type(MPI_Info) and newcomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_split_type.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "split_type",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "newcomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_split_type",
    see_also = {
      "MPI_Comm_split",
      "MPI_Win_allocate_shared",
    },
    signature = "MPI_Comm_split_type(comm, split_type, key, info, newcomm, ierror)",
    standard = "MPI-3.0",
    summary = "Split a communicator by a hardware property, such as shared memory",
  },
  mpi_comm_test_inter = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Comm_test_inter.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Comm_test_inter",
    signature = "MPI_Comm_test_inter(comm, flag, ierror)",
    standard = "MPI-1.0",
  },
  mpi_comm_type_hw_guided = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_TYPE_HW_GUIDED",
    section = "mpif-constants.h",
    type = "integer",
    value = "13",
  },
  mpi_comm_type_hw_unguided = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_TYPE_HW_UNGUIDED",
    section = "mpif-constants.h",
    type = "integer",
    value = "12",
  },
  mpi_comm_type_shared = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_TYPE_SHARED",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_comm_world = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_COMM_WORLD** is the predefined communicator holding all processes\n" ..
      "started by the job launcher. It exists from MPI_Init until MPI_Finalize and\n" ..
      "is the default context for nearly all communication.\n" ..
      "\n" ..
      "Ranks in it run from 0 to size-1 and never change. It cannot be freed. Note\n" ..
      "that a rank number is meaningful only for the communicator it came from --\n" ..
      "a rank taken from MPI_COMM_WORLD is not valid in a communicator produced by\n" ..
      "MPI_Comm_split.",
    example = "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Bcast(x, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMM_WORLD",
    section = "Communicators",
    see_also = {
      "MPI_Comm_rank",
      "MPI_Comm_size",
      "MPI_Comm_dup",
    },
    standard = "MPI-1.0",
    summary = "The communicator containing every process in the job",
    type = "integer",
    value = "0",
  },
  mpi_compare_and_swap = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Compare_and_swap.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "compare_addr",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "result_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Compare_and_swap",
    signature = "MPI_Compare_and_swap(origin_addr, compare_addr, result_addr, datatype, target_rank, target_disp, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMPLEX",
    section = "Datatypes",
    standard = "MPI-1.0",
    type = "integer",
    value = "18",
  },
  mpi_complex16 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMPLEX16",
    section = "mpif-handles.h",
    type = "integer",
    value = "20",
  },
  mpi_complex32 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMPLEX32",
    section = "mpif-handles.h",
    type = "integer",
    value = "21",
  },
  mpi_complex4 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMPLEX4",
    section = "mpif-handles.h",
    type = "integer",
    value = "73",
  },
  mpi_complex8 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COMPLEX8",
    section = "mpif-handles.h",
    type = "integer",
    value = "19",
  },
  mpi_congruent = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CONGRUENT",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_conversion_fn_null = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Conversion_fn_null.3.php",
    interface = {
      {
        intent = "out",
        name = "userbuf",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "filebuf",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "position",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Conversion_fn_null",
    signature = "MPI_Conversion_fn_null(userbuf, datatype, count, filebuf, position, extra_state, ierror)",
    standard = "MPI-3.0",
  },
  mpi_count = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COUNT",
    section = "mpif-handles.h",
    type = "integer",
    value = "72",
  },
  mpi_count_kind = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_COUNT_KIND",
    section = "mpif-config.h",
    type = "integer",
    value = "8",
  },
  mpi_cxx_bool = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CXX_BOOL",
    section = "mpif-handles.h",
    type = "integer",
    value = "54",
  },
  mpi_cxx_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CXX_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "55",
  },
  mpi_cxx_double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CXX_DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "56",
  },
  mpi_cxx_float_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CXX_FLOAT_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "55",
  },
  mpi_cxx_long_double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_CXX_LONG_DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "57",
  },
  mpi_datatype_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DATATYPE_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_dims_create = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Dims_create.3.php",
    interface = {
      {
        intent = "in",
        name = "nnodes",
        type = "integer",
      },
      {
        intent = "in",
        name = "ndims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "dims",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Dims_create",
    see_also = {
      "MPI_Cart_create",
    },
    signature = "MPI_Dims_create(nnodes, ndims, dims, ierror)",
    standard = "MPI-1.0",
    summary = "Suggest a balanced factorisation of a process count into a grid",
  },
  mpi_displacement_current = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DISPLACEMENT_CURRENT",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "-54278278",
  },
  mpi_dist_graph = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DIST_GRAPH",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_dist_graph_create = {
    binding_note = "mpi_f08 spells comm_old as type(MPI_Comm), info as type(MPI_Info) and comm_dist_graph as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Dist_graph_create.3.php",
    interface = {
      {
        intent = "in",
        name = "comm_old",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sources",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "degrees",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "destinations",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "weights",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "reorder",
        type = "logical",
      },
      {
        intent = "out",
        name = "comm_dist_graph",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Dist_graph_create",
    signature = "MPI_Dist_graph_create(comm_old, n, sources, degrees, destinations, weights, info, reorder, comm_dist_graph, ierror)",
    standard = "MPI-2.2",
  },
  mpi_dist_graph_create_adjacent = {
    binding_note = "mpi_f08 spells comm_old as type(MPI_Comm), info as type(MPI_Info) and comm_dist_graph as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Dist_graph_create_adjacent.3.php",
    interface = {
      {
        intent = "in",
        name = "comm_old",
        type = "integer",
      },
      {
        intent = "in",
        name = "indegree",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sources",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sourceweights",
        type = "integer",
      },
      {
        intent = "in",
        name = "outdegree",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "destinations",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "destweights",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "reorder",
        type = "logical",
      },
      {
        intent = "out",
        name = "comm_dist_graph",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Dist_graph_create_adjacent",
    signature = "MPI_Dist_graph_create_adjacent(comm_old, indegree, sources, sourceweights, outdegree, destinations, destweights, info, reorder, comm_dist_graph, ierror)",
    standard = "MPI-2.2",
  },
  mpi_dist_graph_neighbors = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Dist_graph_neighbors.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxindegree",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "sources",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "sourceweights",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxoutdegree",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "destinations",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "destweights",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Dist_graph_neighbors",
    signature = "MPI_Dist_graph_neighbors(comm, maxindegree, sources, sourceweights, maxoutdegree, destinations, destweights, ierror)",
    standard = "MPI-2.2",
  },
  mpi_dist_graph_neighbors_count = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Dist_graph_neighbors_count.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "indegree",
        type = "integer",
      },
      {
        intent = "out",
        name = "outdegree",
        type = "integer",
      },
      {
        intent = "out",
        name = "weighted",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Dist_graph_neighbors_count",
    signature = "MPI_Dist_graph_neighbors_count(comm, indegree, outdegree, weighted, ierror)",
    standard = "MPI-2.2",
  },
  mpi_distribute_block = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DISTRIBUTE_BLOCK",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_distribute_cyclic = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DISTRIBUTE_CYCLIC",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_distribute_dflt_darg = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DISTRIBUTE_DFLT_DARG",
    section = "mpif-constants.h",
    type = "integer",
    value = "-1",
  },
  mpi_distribute_none = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DISTRIBUTE_NONE",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_double = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DOUBLE",
    section = "mpif-handles.h",
    type = "integer",
    value = "46",
  },
  mpi_double_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DOUBLE_COMPLEX",
    section = "mpif-handles.h",
    type = "integer",
    value = "22",
  },
  mpi_double_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DOUBLE_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "49",
  },
  mpi_double_precision = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_DOUBLE_PRECISION** is the datatype handle matching Fortran\n" ..
      "DOUBLE PRECISION, i.e. REAL*8 / REAL(KIND=8) on every common platform.\n" ..
      "\n" ..
      "The datatype must match the buffer's actual Fortran type. Passing\n" ..
      "MPI_REAL for a REAL*8 array is not diagnosed by anything -- not the compiler,\n" ..
      "which never sees the connection, and not MPI, which trusts the handle -- and\n" ..
      "transfers half the bytes. Sender and receiver must also agree.",
    example = "  real(8) :: x(n)\n" ..
      "  call MPI_Bcast(x, n, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_DOUBLE_PRECISION",
    section = "Datatypes",
    see_also = {
      "MPI_REAL",
      "MPI_INTEGER",
      "MPI_Bcast",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for Fortran DOUBLE PRECISION",
    type = "integer",
    value = "17",
  },
  mpi_dup_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_DUP_FN.3.php",
    interface = {
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer",
      },
      {
        name = "attribute_val_in",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_DUP_FN",
    signature = "MPI_DUP_FN(comm, comm_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-1.0",
  },
  mpi_err_access = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_ACCESS",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Permission denied on a file operation",
    type = "integer",
    value = "20",
  },
  mpi_err_amode = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_AMODE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid or contradictory access mode passed to MPI_File_open",
    type = "integer",
    value = "21",
  },
  mpi_err_arg = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_ARG",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "An argument was invalid in a way no other class describes",
    type = "integer",
    value = "13",
  },
  mpi_err_assert = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_ASSERT",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid assert argument to a one-sided synchronisation call",
    type = "integer",
    value = "22",
  },
  mpi_err_bad_file = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_BAD_FILE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Malformed file name",
    type = "integer",
    value = "23",
  },
  mpi_err_base = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_BASE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid base address passed to a window or memory call",
    type = "integer",
    value = "24",
  },
  mpi_err_buffer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_BUFFER",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid buffer pointer",
    type = "integer",
    value = "1",
  },
  mpi_err_comm = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_COMM",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid communicator",
    type = "integer",
    value = "5",
  },
  mpi_err_conversion = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_CONVERSION",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A user-defined data representation conversion function failed",
    type = "integer",
    value = "25",
  },
  mpi_err_count = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_COUNT",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid count argument -- counts must be non-negative",
    type = "integer",
    value = "2",
  },
  mpi_err_dims = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_DIMS",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid dimension argument to a topology call",
    type = "integer",
    value = "12",
  },
  mpi_err_disp = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_DISP",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid displacement argument in a one-sided call",
    type = "integer",
    value = "26",
  },
  mpi_err_dup_datarep = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_DUP_DATAREP",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A data representation of that name is already registered",
    type = "integer",
    value = "27",
  },
  mpi_err_file = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_FILE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid file handle",
    type = "integer",
    value = "30",
  },
  mpi_err_file_exists = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_FILE_EXISTS",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The file already exists",
    type = "integer",
    value = "28",
  },
  mpi_err_file_in_use = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_FILE_IN_USE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The file is open by some other process",
    type = "integer",
    value = "29",
  },
  mpi_err_group = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_GROUP",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid group",
    type = "integer",
    value = "9",
  },
  mpi_err_in_status = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_IN_STATUS",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The real error is in the status objects, not in this code",
    type = "integer",
    value = "18",
  },
  mpi_err_info = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_INFO",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid info object",
    type = "integer",
    value = "34",
  },
  mpi_err_info_key = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_INFO_KEY",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Info key too long, or otherwise invalid",
    type = "integer",
    value = "31",
  },
  mpi_err_info_nokey = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_INFO_NOKEY",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The info object has no such key",
    type = "integer",
    value = "32",
  },
  mpi_err_info_value = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_INFO_VALUE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Info value too long, or otherwise invalid",
    type = "integer",
    value = "33",
  },
  mpi_err_intern = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_INTERN",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "An internal error in the MPI implementation",
    type = "integer",
    value = "17",
  },
  mpi_err_io = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_IO",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "An I/O error occurred",
    type = "integer",
    value = "35",
  },
  mpi_err_keyval = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_KEYVAL",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid attribute key",
    type = "integer",
    value = "36",
  },
  mpi_err_lastcode = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_LASTCODE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The largest error code the implementation may return",
    type = "integer",
    value = "92",
  },
  mpi_err_locktype = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_LOCKTYPE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid lock type passed to MPI_Win_lock",
    type = "integer",
    value = "37",
  },
  mpi_err_name = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_NAME",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid service name in a name-publishing call",
    type = "integer",
    value = "38",
  },
  mpi_err_no_mem = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_NO_MEM",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "MPI_Alloc_mem could not satisfy the request",
    type = "integer",
    value = "39",
  },
  mpi_err_no_space = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_NO_SPACE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The filesystem is out of space",
    type = "integer",
    value = "41",
  },
  mpi_err_no_such_file = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_NO_SUCH_FILE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The file does not exist",
    type = "integer",
    value = "42",
  },
  mpi_err_not_same = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_NOT_SAME",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A collective argument differed between ranks",
    type = "integer",
    value = "40",
  },
  mpi_err_op = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_OP",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid reduction operation",
    type = "integer",
    value = "10",
  },
  mpi_err_other = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_OTHER",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A known error with no more specific class",
    type = "integer",
    value = "16",
  },
  mpi_err_pending = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_PENDING",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The operation is still pending; not an error in itself",
    type = "integer",
    value = "19",
  },
  mpi_err_port = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_PORT",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid port name in a connect call",
    type = "integer",
    value = "43",
  },
  mpi_err_proc_aborted = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_PROC_ABORTED",
    section = "mpif-constants.h",
    type = "integer",
    value = "74",
  },
  mpi_err_proc_failed = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_PROC_FAILED",
    section = "mpif-constants.h",
    type = "integer",
    value = "75",
  },
  mpi_err_proc_failed_pending = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_PROC_FAILED_PENDING",
    section = "mpif-constants.h",
    type = "integer",
    value = "76",
  },
  mpi_err_quota = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_QUOTA",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A filesystem quota was exceeded",
    type = "integer",
    value = "44",
  },
  mpi_err_rank = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RANK",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid rank for the given communicator",
    type = "integer",
    value = "6",
  },
  mpi_err_read_only = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_READ_ONLY",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The file or filesystem is read-only",
    type = "integer",
    value = "45",
  },
  mpi_err_request = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_REQUEST",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid request handle",
    type = "integer",
    value = "7",
  },
  mpi_err_revoked = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_REVOKED",
    section = "mpif-constants.h",
    type = "integer",
    value = "77",
  },
  mpi_err_rma_attach = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_ATTACH",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Memory could not be attached to a dynamic window",
    type = "integer",
    value = "69",
  },
  mpi_err_rma_conflict = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_CONFLICT",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Conflicting concurrent accesses to a window",
    type = "integer",
    value = "46",
  },
  mpi_err_rma_flavor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_FLAVOR",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The call is not valid for this flavour of window",
    type = "integer",
    value = "70",
  },
  mpi_err_rma_range = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_RANGE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The target of a one-sided access lies outside the window",
    type = "integer",
    value = "68",
  },
  mpi_err_rma_shared = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_SHARED",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Memory could not be shared between the ranks of the window",
    type = "integer",
    value = "71",
  },
  mpi_err_rma_sync = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_RMA_SYNC",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Wrong one-sided synchronisation call for the current epoch",
    type = "integer",
    value = "47",
  },
  mpi_err_root = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_ROOT",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid root rank",
    type = "integer",
    value = "8",
  },
  mpi_err_service = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_SERVICE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid service name in a name-publishing call",
    type = "integer",
    value = "48",
  },
  mpi_err_session = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_SESSION",
    section = "mpif-constants.h",
    type = "integer",
    value = "78",
  },
  mpi_err_size = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_SIZE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid size argument in a one-sided call",
    type = "integer",
    value = "49",
  },
  mpi_err_spawn = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_SPAWN",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "A process could not be spawned",
    type = "integer",
    value = "50",
  },
  mpi_err_tag = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_TAG",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid tag -- tags must be non-negative and at most MPI_TAG_UB",
    type = "integer",
    value = "4",
  },
  mpi_err_topology = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_TOPOLOGY",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid topology on the communicator",
    type = "integer",
    value = "11",
  },
  mpi_err_truncate = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_TRUNCATE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The message was longer than the receive buffer",
    type = "integer",
    value = "15",
  },
  mpi_err_type = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_TYPE",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid datatype, or one that was never committed",
    type = "integer",
    value = "3",
  },
  mpi_err_unknown = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_UNKNOWN",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "An error of a class the implementation cannot name",
    type = "integer",
    value = "14",
  },
  mpi_err_unsupported_datarep = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_UNSUPPORTED_DATAREP",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The requested data representation is not supported",
    type = "integer",
    value = "51",
  },
  mpi_err_unsupported_operation = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_UNSUPPORTED_OPERATION",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "The operation is not supported on this file or window",
    type = "integer",
    value = "52",
  },
  mpi_err_value_too_large = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_VALUE_TOO_LARGE",
    section = "mpif-constants.h",
    type = "integer",
    value = "79",
  },
  mpi_err_win = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERR_WIN",
    section = "Error codes",
    see_also = {
      "MPI_Error_string",
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    standard = "MPI-1.0",
    summary = "Invalid window handle",
    type = "integer",
    value = "53",
  },
  mpi_errcodes_ignore = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERRCODES_IGNORE",
    section = "mpif-sentinels.h",
    type = "integer",
  },
  mpi_errhandler_free = {
    binding_note = "mpi_f08 spells errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Errhandler_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Errhandler_free",
    signature = "MPI_Errhandler_free(errhandler, ierror)",
    standard = "MPI-1.0",
  },
  mpi_errhandler_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERRHANDLER_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_error = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_ERROR** indexes a status array at the per-operation error code. It is\n" ..
      "only filled in meaningfully by the multiple-completion calls\n" ..
      "(MPI_Waitall, MPI_Testall and friends), where one request among many may have\n" ..
      "failed; for a single MPI_Recv the code is the routine's own **ierror** and\n" ..
      "this field is not set.",
    example = "  call MPI_Waitall(n, reqs, stats, ierr)\n" ..
      "  if (ierr /= MPI_SUCCESS) then\n" ..
      "     do i = 1, n\n" ..
      "        if (stats(MPI_ERROR, i) /= MPI_SUCCESS) call report(i)\n" ..
      "     end do\n" ..
      "  end if",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERROR",
    section = "Status",
    see_also = {
      "MPI_SOURCE",
      "MPI_Waitall",
    },
    standard = "MPI-1.0",
    summary = "Status array index holding the error code",
    type = "integer",
    value = "3",
  },
  mpi_error_class = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Error_class.3.php",
    interface = {
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "errorclass",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Error_class",
    see_also = {
      "MPI_Error_string",
    },
    signature = "MPI_Error_class(errorcode, errorclass, ierror)",
    standard = "MPI-1.0",
    summary = "The error class an error code belongs to",
  },
  mpi_error_string = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Error_string.3.php",
    interface = {
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "string",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Error_string",
    see_also = {
      "MPI_Error_class",
      "MPI_SUCCESS",
    },
    signature = "MPI_Error_string(errorcode, string, resultlen, ierror)",
    standard = "MPI-1.0",
    summary = "The human-readable text of an MPI error code",
  },
  mpi_errors_abort = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERRORS_ABORT",
    section = "mpif-handles.h",
    type = "integer",
    value = "3",
  },
  mpi_errors_are_fatal = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERRORS_ARE_FATAL",
    section = "mpif-handles.h",
    type = "integer",
    value = "1",
  },
  mpi_errors_return = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ERRORS_RETURN",
    section = "mpif-handles.h",
    type = "integer",
    value = "2",
  },
  mpi_exscan = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Exscan.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Exscan",
    see_also = {
      "MPI_Scan",
      "MPI_Reduce",
    },
    signature = "MPI_Exscan(sendbuf, recvbuf, count, datatype, op, comm, ierror)",
    standard = "MPI-2.0",
    summary = "Exclusive prefix reduction across the ranks of a communicator",
  },
  mpi_exscan_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Exscan_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Exscan_init",
    signature = "MPI_Exscan_init(sendbuf, recvbuf, count, datatype, op, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_f08 = {
    description = "**mpi_f08** is the recommended MPI module for modern Fortran programs. It\n" ..
      "provides type-safe interfaces using Fortran 2008 features including derived\n" ..
      "types for MPI handles, assumed-type (`TYPE(*)`) for choice buffers, and\n" ..
      "optional error arguments. This module replaces the older `use mpi` and\n" ..
      "`include 'mpif.h'` approaches with improved type safety and better\n" ..
      "compiler error messages.",
    example = "program demo_mpi_f08\n" ..
      "  use mpi_f08\n" ..
      "  implicit none\n" ..
      "  type(MPI_Comm) :: comm\n" ..
      "  type(MPI_Status) :: status\n" ..
      "  integer :: rank, nprocs, ierr\n" ..
      "  real(8) :: sendbuf, recvbuf\n" ..
      "\n" ..
      "  call MPI_Init(ierr)\n" ..
      "\n" ..
      "  comm = MPI_COMM_WORLD\n" ..
      "  call MPI_Comm_rank(comm, rank, ierr)\n" ..
      "  call MPI_Comm_size(comm, nprocs, ierr)\n" ..
      "\n" ..
      "  sendbuf = real(rank, 8)\n" ..
      "\n" ..
      "  ! Use MPI_Allreduce with derived type handles\n" ..
      "  call MPI_Allreduce(sendbuf, recvbuf, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, comm, ierr)\n" ..
      "\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,F8.2)', 'Sum of all ranks: ', recvbuf\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Point-to-point with status\n" ..
      "  if (nprocs >= 2) then\n" ..
      "    if (rank == 0) then\n" ..
      "      call MPI_Send(sendbuf, 1, MPI_DOUBLE_PRECISION, 1, 100, comm, ierr)\n" ..
      "    else if (rank == 1) then\n" ..
      "      call MPI_Recv(recvbuf, 1, MPI_DOUBLE_PRECISION, 0, 100, comm, status, ierr)\n" ..
      "      print '(A,I0,A,I0)', 'Received from rank ', status%MPI_SOURCE, &\n" ..
      "            ' with tag ', status%MPI_TAG\n" ..
      "    end if\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_f08",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_T.3.php",
    kind = "module",
    module = "mpi_f08",
    name = "mpi_f08",
    params = {
      mpi_comm = "Derived type for communicator handles. The predefined communicator MPI_COMM_WORLD is of this type.",
      mpi_datatype = "Derived type for datatype handles. Predefined types include MPI_INTEGER, MPI_REAL, MPI_DOUBLE_PRECISION, MPI_COMPLEX, etc.",
      mpi_op = "Derived type for reduction operation handles. Predefined operations include MPI_SUM, MPI_MAX, MPI_MIN, MPI_PROD, etc.",
      mpi_request = "Derived type for nonblocking operation handles.",
      mpi_status = "Derived type for status information returned by receive operations. Contains source, tag, and error fields.",
    },
    result = "After `use mpi_f08`, all MPI routines, constants, and derived types become\n" ..
      "available in the current scope. The module provides the complete MPI\n" ..
      "interface with modern Fortran features.",
    section = "Bindings",
    see_also = {
      "MPI_Init",
      "MPI_Finalize",
      "MPI_Comm_rank",
      "MPI_Send",
      "MPI_Recv",
      "MPI_Allreduce",
    },
    signature = "use mpi_f08",
    standard = "MPI-3.0",
    summary = "Modern Fortran MPI bindings module with type-safe interfaces",
  },
  mpi_f_sync_reg = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_F_sync_reg.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "inout",
        name = "buf",
        type = "<any type>",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_F_sync_reg",
    signature = "MPI_F_sync_reg(buf)",
    standard = "MPI-3.0",
  },
  mpi_fetch_and_op = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Fetch_and_op.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "result_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Fetch_and_op",
    signature = "MPI_Fetch_and_op(origin_addr, result_addr, datatype, target_rank, target_disp, op, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_file_call_errhandler = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_call_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_call_errhandler",
    signature = "MPI_File_call_errhandler(fh, errorcode, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_close = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_close.3.php",
    interface = {
      {
        intent = "inout",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_close",
    signature = "MPI_File_close(fh, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_create_errhandler = {
    binding_note = "mpi_f08 spells errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_create_errhandler.3.php",
    interface = {
      {
        name = "function",
        type = "external",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_create_errhandler",
    signature = "MPI_File_create_errhandler(function, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_delete = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_delete.3.php",
    interface = {
      {
        intent = "in",
        name = "filename",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_delete",
    signature = "MPI_File_delete(filename, info, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_amode = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_amode.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "amode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_amode",
    signature = "MPI_File_get_amode(fh, amode, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_atomicity = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_atomicity.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_atomicity",
    signature = "MPI_File_get_atomicity(fh, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_byte_offset = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_byte_offset.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "disp",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_byte_offset",
    signature = "MPI_File_get_byte_offset(fh, offset, disp, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_errhandler = {
    binding_note = "mpi_f08 spells file as type(MPI_File) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "file",
        type = "integer",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_errhandler",
    signature = "MPI_File_get_errhandler(file, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_group = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_group.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_group",
    signature = "MPI_File_get_group(fh, group, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_info = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and info_used as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_info.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "info_used",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_info",
    signature = "MPI_File_get_info(fh, info_used, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_position = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_position.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "offset",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_position",
    signature = "MPI_File_get_position(fh, offset, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_position_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_position_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "offset",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_position_shared",
    signature = "MPI_File_get_position_shared(fh, offset, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_size = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_size.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_size",
    signature = "MPI_File_get_size(fh, size, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_type_extent = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_type_extent.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_type_extent",
    signature = "MPI_File_get_type_extent(fh, datatype, extent, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_get_view = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), etype as type(MPI_Datatype) and filetype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_get_view.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "disp",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "etype",
        type = "integer",
      },
      {
        intent = "out",
        name = "filetype",
        type = "integer",
      },
      {
        intent = "out",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_get_view",
    signature = "MPI_File_get_view(fh, disp, etype, filetype, datarep, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iread = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iread.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iread",
    signature = "MPI_File_iread(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iread_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iread_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iread_all",
    signature = "MPI_File_iread_all(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-3.1",
  },
  mpi_file_iread_at = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iread_at.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iread_at",
    signature = "MPI_File_iread_at(fh, offset, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iread_at_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iread_at_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iread_at_all",
    signature = "MPI_File_iread_at_all(fh, offset, buf, count, datatype, request, ierror)",
    standard = "MPI-3.1",
  },
  mpi_file_iread_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iread_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iread_shared",
    signature = "MPI_File_iread_shared(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iwrite = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iwrite.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iwrite",
    signature = "MPI_File_iwrite(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iwrite_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iwrite_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iwrite_all",
    signature = "MPI_File_iwrite_all(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-3.1",
  },
  mpi_file_iwrite_at = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iwrite_at.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iwrite_at",
    signature = "MPI_File_iwrite_at(fh, offset, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_iwrite_at_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iwrite_at_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iwrite_at_all",
    signature = "MPI_File_iwrite_at_all(fh, offset, buf, count, datatype, request, ierror)",
    standard = "MPI-3.1",
  },
  mpi_file_iwrite_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_iwrite_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_iwrite_shared",
    signature = "MPI_File_iwrite_shared(fh, buf, count, datatype, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_FILE_NULL",
    section = "mpif-io-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_file_open = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), info as type(MPI_Info) and fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_open.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "filename",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "amode",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_open",
    signature = "MPI_File_open(comm, filename, amode, info, fh, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_preallocate = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_preallocate.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_preallocate",
    signature = "MPI_File_preallocate(fh, size, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read",
    signature = "MPI_File_read(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_all",
    signature = "MPI_File_read_all(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_all_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_all_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_all_begin",
    signature = "MPI_File_read_all_begin(fh, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_all_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_all_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_all_end",
    signature = "MPI_File_read_all_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_at = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_at.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_at",
    signature = "MPI_File_read_at(fh, offset, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_at_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_at_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_at_all",
    signature = "MPI_File_read_at_all(fh, offset, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_at_all_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_at_all_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_at_all_begin",
    signature = "MPI_File_read_at_all_begin(fh, offset, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_at_all_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_at_all_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_at_all_end",
    signature = "MPI_File_read_at_all_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_ordered = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_ordered.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_ordered",
    signature = "MPI_File_read_ordered(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_ordered_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_ordered_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_ordered_begin",
    signature = "MPI_File_read_ordered_begin(fh, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_ordered_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_ordered_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_ordered_end",
    signature = "MPI_File_read_ordered_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_read_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_read_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_read_shared",
    signature = "MPI_File_read_shared(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_seek = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_seek.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "whence",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_seek",
    signature = "MPI_File_seek(fh, offset, whence, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_seek_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_seek_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "whence",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_seek_shared",
    signature = "MPI_File_seek_shared(fh, offset, whence, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_set_atomicity = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_set_atomicity.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_set_atomicity",
    signature = "MPI_File_set_atomicity(fh, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_set_errhandler = {
    binding_note = "mpi_f08 spells file as type(MPI_File) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_set_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "file",
        type = "integer",
      },
      {
        intent = "in",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_set_errhandler",
    signature = "MPI_File_set_errhandler(file, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_set_info = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_set_info.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_set_info",
    signature = "MPI_File_set_info(fh, info, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_set_size = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_set_size.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_set_size",
    signature = "MPI_File_set_size(fh, size, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_set_view = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), etype as type(MPI_Datatype), filetype as type(MPI_Datatype) and info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_set_view.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "etype",
        type = "integer",
      },
      {
        intent = "in",
        name = "filetype",
        type = "integer",
      },
      {
        intent = "in",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_set_view",
    signature = "MPI_File_set_view(fh, disp, etype, filetype, datarep, info, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_sync = {
    binding_note = "mpi_f08 spells fh as type(MPI_File); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_sync.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_sync",
    signature = "MPI_File_sync(fh, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write",
    signature = "MPI_File_write(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_all",
    signature = "MPI_File_write_all(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_all_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_all_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_all_begin",
    signature = "MPI_File_write_all_begin(fh, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_all_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_all_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_all_end",
    signature = "MPI_File_write_all_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_at = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_at.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_at",
    signature = "MPI_File_write_at(fh, offset, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_at_all = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_at_all.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_at_all",
    signature = "MPI_File_write_at_all(fh, offset, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_at_all_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_at_all_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        intent = "in",
        name = "offset",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_at_all_begin",
    signature = "MPI_File_write_at_all_begin(fh, offset, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_at_all_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_at_all_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_at_all_end",
    signature = "MPI_File_write_at_all_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_ordered = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_ordered.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_ordered",
    signature = "MPI_File_write_ordered(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_ordered_begin = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_ordered_begin.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_ordered_begin",
    signature = "MPI_File_write_ordered_begin(fh, buf, count, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_ordered_end = {
    binding_note = "mpi_f08 spells fh as type(MPI_File) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_ordered_end.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_ordered_end",
    signature = "MPI_File_write_ordered_end(fh, buf, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_file_write_shared = {
    binding_note = "mpi_f08 spells fh as type(MPI_File), datatype as type(MPI_Datatype) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_File_write_shared.3.php",
    interface = {
      {
        intent = "in",
        name = "fh",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_File_write_shared",
    signature = "MPI_File_write_shared(fh, buf, count, datatype, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_finalize = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    description = "**MPI_Finalize** shuts down the MPI environment and releases its resources.\n" ..
      "Every process that called MPI_Init must call it, and no MPI call other than\n" ..
      "MPI_Initialized and MPI_Finalized is legal afterwards.\n" ..
      "\n" ..
      "It is not an exit. Execution continues with the next statement, which is why\n" ..
      "rank-0 summary output is usually written after it. It also does not cancel\n" ..
      "outstanding communication: a pending non-blocking request or an unreceived\n" ..
      "message makes the behaviour undefined, so complete or free them first.\n" ..
      "\n" ..
      "To abort on an error path, use MPI_Abort -- reaching MPI_Finalize requires\n" ..
      "every process to get there, which a failing process by definition will not.",
    example = "  ! Normal shutdown\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "  ! Perfectly legal after finalize -- this is not an exit\n" ..
      "  if (rank == 0) print *, 'Total energy: ', etot\n" ..
      "  stop",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Finalize.3.php",
    interface = {
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Finalize",
    params = {
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "Returns after MPI has been shut down. The program continues normally;\n" ..
      "only MPI is unavailable.",
    see_also = {
      "MPI_Init",
      "MPI_Abort",
      "MPI_Barrier",
    },
    signature = "MPI_Finalize(ierror)",
    standard = "MPI-1.0",
    summary = "Shut down the MPI execution environment",
  },
  mpi_finalized = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Finalized.3.php",
    interface = {
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Finalized",
    see_also = {
      "MPI_Finalize",
      "MPI_Initialized",
    },
    signature = "MPI_Finalized(flag, ierror)",
    standard = "MPI-2.0",
    summary = "Test whether MPI_Finalize has already been called",
  },
  mpi_float = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_FLOAT",
    section = "mpif-handles.h",
    type = "integer",
    value = "45",
  },
  mpi_float_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_FLOAT_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "48",
  },
  mpi_free_mem = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Free_mem.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "base",
        type = "<any type>",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Free_mem",
    see_also = {
      "MPI_Alloc_mem",
    },
    signature = "MPI_Free_mem(base, ierror)",
    standard = "MPI-2.0",
    summary = "Release memory obtained from MPI_Alloc_mem",
  },
  mpi_ft = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_FT",
    section = "mpif-constants.h",
    type = "integer",
    value = "12",
  },
  mpi_gather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Gather** collects an equal-sized block from every process into a\n" ..
      "single array on **root**, ordered by rank.\n" ..
      "\n" ..
      "The argument that trips everyone: **recvcount** is the number of elements\n" ..
      "received from EACH process, not the total. It is normally equal to\n" ..
      "**sendcount**. The receive buffer must nevertheless be large enough for\n" ..
      "recvcount * nprocs elements, and it need only exist on **root**.\n" ..
      "\n" ..
      "For unequal block sizes use MPI_Gatherv; for the result on every rank, use\n" ..
      "MPI_Allgather.",
    example = "  real(8) :: mine(10), all(10*nprocs)\n" ..
      "  call MPI_Gather(mine, 10, MPI_DOUBLE_PRECISION, &\n" ..
      "                  all,  10, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Gather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Gather",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      recvbuf = "Receive buffer; significant only on **root**, sized for recvcount * nprocs.",
      recvcount = "Elements received from EACH process -- not the total.",
      recvtype = "Datatype of the received elements.",
      root = "Rank collecting the data.",
      sendbuf = "Data contributed by this process.",
      sendcount = "Number of elements this process sends.",
      sendtype = "Datatype of the sent elements.",
    },
    result = "On **root**, **recvbuf** holds every process's contribution in rank order.",
    see_also = {
      "MPI_Gatherv",
      "MPI_Allgather",
      "MPI_Scatter",
    },
    signature = "MPI_Gather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Collect data from all processes onto one",
  },
  mpi_gather_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Gather_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Gather_init",
    signature = "MPI_Gather_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_gatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Gatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Gatherv",
    see_also = {
      "MPI_Gather",
      "MPI_Scatterv",
    },
    signature = "MPI_Gatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Gather a varying number of elements from each rank to the root",
  },
  mpi_gatherv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Gatherv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Gatherv_init",
    signature = "MPI_Gatherv_init(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_get = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get.3.php",
    interface = {
      {
        dim = "(*)",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get",
    see_also = {
      "MPI_Put",
      "MPI_Win_fence",
    },
    signature = "MPI_Get(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, win, ierror)",
    standard = "MPI-2.0",
    summary = "Read from another rank's window, one-sided",
  },
  mpi_get_accumulate = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), result_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), op as type(MPI_Op) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_accumulate.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "result_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "result_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "result_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_accumulate",
    signature = "MPI_Get_accumulate(origin_addr, origin_count, origin_datatype, result_addr, result_count, result_datatype, target_rank, target_disp, target_count, target_datatype, op, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_get_address = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_address.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "location",
        type = "<any type>",
      },
      {
        intent = "out",
        name = "address",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_address",
    see_also = {
      "MPI_Type_create_struct",
      "MPI_Aint_add",
    },
    signature = "MPI_Get_address(location, address, ierror)",
    standard = "MPI-2.0",
    summary = "Byte address of a variable, for use in datatype displacements",
  },
  mpi_get_count = {
    binding_note = "mpi_f08 spells status as type(MPI_Status) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    description = "**MPI_Get_count** answers the question MPI_Recv cannot: the count argument\n" ..
      "to MPI_Recv is the buffer CAPACITY, an upper bound, not the size of the\n" ..
      "message that arrived. A shorter message is accepted without complaint, and\n" ..
      "the only way to learn its real length is to ask the status object afterwards.\n" ..
      "\n" ..
      "Because the answer is expressed in elements of **datatype**, passing a\n" ..
      "different datatype than the receive used gives a wrong -- not an erroneous --\n" ..
      "answer. If the byte count is not an exact multiple of the datatype's extent,\n" ..
      "**count** comes back as MPI_UNDEFINED.",
    example = "  integer :: status(MPI_STATUS_SIZE), nrecv, ierr\n" ..
      "  real(8) :: buf(LPMX)\n" ..
      "\n" ..
      "  ! LPMX is the CAPACITY; the sender may have sent far fewer\n" ..
      "  call MPI_Recv(buf, LPMX, MPI_DOUBLE_PRECISION, MPI_ANY_SOURCE, &\n" ..
      "                tag, MPI_COMM_WORLD, status, ierr)\n" ..
      "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, nrecv, ierr)\n" ..
      "\n" ..
      "  ! Only the first nrecv entries are meaningful\n" ..
      "  do i = 1, nrecv\n" ..
      "     call absorb(buf(i))\n" ..
      "  end do",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_count.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "in",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "count",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_count",
    params = {
      count = "Number of **datatype** elements received, or MPI_UNDEFINED when the message length is not a whole multiple of the datatype extent.",
      datatype = "The datatype the message was received with. Using a different one silently yields a wrong count.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      status = "Status array from a completed MPI_Recv, MPI_Probe or MPI_Wait. Declared `INTEGER status(MPI_STATUS_SIZE)` in the Fortran binding.",
    },
    result = "**count** holds the number of elements actually received, which may be\n" ..
      "anything from 0 up to the capacity passed to MPI_Recv.",
    see_also = {
      "MPI_Recv",
      "MPI_Probe",
      "MPI_STATUS_SIZE",
    },
    signature = "MPI_Get_count(status, datatype, count, ierror)",
    standard = "MPI-1.0",
    summary = "Report how many elements were actually received",
  },
  mpi_get_elements = {
    binding_note = "mpi_f08 spells status as type(MPI_Status) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_elements.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "in",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "count",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_elements",
    signature = "MPI_Get_elements(status, datatype, count, ierror)",
    standard = "MPI-1.0",
  },
  mpi_get_elements_x = {
    binding_note = "mpi_f08 spells status as type(MPI_Status) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_elements_x.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "in",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "count",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_elements_x",
    signature = "MPI_Get_elements_x(status, datatype, count, ierror)",
    standard = "MPI-3.0",
  },
  mpi_get_library_version = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_library_version.3.php",
    interface = {
      {
        intent = "out",
        name = "version",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_library_version",
    see_also = {
      "MPI_Get_version",
    },
    signature = "MPI_Get_library_version(version, resultlen, ierror)",
    standard = "MPI-3.0",
    summary = "The implementation's own version string",
  },
  mpi_get_processor_name = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    description = "**MPI_Get_processor_name** returns an implementation-defined identifier for\n" ..
      "the node -- usually the hostname. Its practical use is confirming process\n" ..
      "placement across nodes.\n" ..
      "\n" ..
      "Declare **name** with length MPI_MAX_PROCESSOR_NAME and print only\n" ..
      "name(1:resultlen); the rest of the string is unspecified.",
    example = "  character(len=MPI_MAX_PROCESSOR_NAME) :: nodename\n" ..
      "  call MPI_Get_processor_name(nodename, nlen, ierr)\n" ..
      "  write(*,*) 'rank ', rank, ' on ', nodename(1:nlen)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_processor_name.3.php",
    interface = {
      {
        intent = "out",
        name = "name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_processor_name",
    params = {
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      name = "Buffer of at least MPI_MAX_PROCESSOR_NAME characters.",
      resultlen = "Significant length of **name**.",
    },
    result = "**name**(1:**resultlen**) identifies the node.",
    see_also = {
      "MPI_Comm_rank",
    },
    signature = "MPI_Get_processor_name(name, resultlen, ierror)",
    standard = "MPI-1.0",
    summary = "Get the name of the node this process runs on",
  },
  mpi_get_version = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Get_version.3.php",
    interface = {
      {
        intent = "out",
        name = "version",
        type = "integer",
      },
      {
        intent = "out",
        name = "subversion",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Get_version",
    see_also = {
      "MPI_Get_library_version",
    },
    signature = "MPI_Get_version(version, subversion, ierror)",
    standard = "MPI-2.0",
    summary = "The MPI standard version the library implements",
  },
  mpi_graph = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_GRAPH",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_graph_create = {
    binding_note = "mpi_f08 spells comm_old as type(MPI_Comm) and comm_graph as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graph_create.3.php",
    interface = {
      {
        intent = "in",
        name = "comm_old",
        type = "integer",
      },
      {
        intent = "in",
        name = "nnodes",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "index",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "edges",
        type = "integer",
      },
      {
        intent = "in",
        name = "reorder",
        type = "logical",
      },
      {
        intent = "out",
        name = "comm_graph",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graph_create",
    signature = "MPI_Graph_create(comm_old, nnodes, index, edges, reorder, comm_graph, ierror)",
    standard = "MPI-1.0",
  },
  mpi_graph_get = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graph_get.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxindex",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxedges",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "index",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "edges",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graph_get",
    signature = "MPI_Graph_get(comm, maxindex, maxedges, index, edges, ierror)",
    standard = "MPI-1.0",
  },
  mpi_graph_map = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graph_map.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "nnodes",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "index",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "edges",
        type = "integer",
      },
      {
        intent = "out",
        name = "newrank",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graph_map",
    signature = "MPI_Graph_map(comm, nnodes, index, edges, newrank, ierror)",
    standard = "MPI-1.0",
  },
  mpi_graph_neighbors = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graph_neighbors.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "maxneighbors",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "neighbors",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graph_neighbors",
    signature = "MPI_Graph_neighbors(comm, rank, maxneighbors, neighbors, ierror)",
    standard = "MPI-1.0",
  },
  mpi_graph_neighbors_count = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graph_neighbors_count.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "out",
        name = "nneighbors",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graph_neighbors_count",
    signature = "MPI_Graph_neighbors_count(comm, rank, nneighbors, ierror)",
    standard = "MPI-1.0",
  },
  mpi_graphdims_get = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Graphdims_get.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "nnodes",
        type = "integer",
      },
      {
        intent = "out",
        name = "nedges",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Graphdims_get",
    signature = "MPI_Graphdims_get(comm, nnodes, nedges, ierror)",
    standard = "MPI-1.0",
  },
  mpi_grequest_complete = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Grequest_complete.3.php",
    interface = {
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Grequest_complete",
    signature = "MPI_Grequest_complete(request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_grequest_start = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Grequest_start.3.php",
    interface = {
      {
        name = "query_fn",
        type = "external",
      },
      {
        name = "free_fn",
        type = "external",
      },
      {
        name = "cancel_fn",
        type = "external",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Grequest_start",
    signature = "MPI_Grequest_start(query_fn, free_fn, cancel_fn, extra_state, request, ierror)",
    standard = "MPI-2.0",
  },
  mpi_group_compare = {
    binding_note = "mpi_f08 spells group1 as type(MPI_Group) and group2 as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_compare.3.php",
    interface = {
      {
        intent = "in",
        name = "group1",
        type = "integer",
      },
      {
        intent = "in",
        name = "group2",
        type = "integer",
      },
      {
        intent = "out",
        name = "result",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_compare",
    signature = "MPI_Group_compare(group1, group2, result, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_difference = {
    binding_note = "mpi_f08 spells group1 as type(MPI_Group), group2 as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_difference.3.php",
    interface = {
      {
        intent = "in",
        name = "group1",
        type = "integer",
      },
      {
        intent = "in",
        name = "group2",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_difference",
    signature = "MPI_Group_difference(group1, group2, newgroup, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_empty = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_GROUP_EMPTY",
    section = "mpif-handles.h",
    type = "integer",
    value = "1",
  },
  mpi_group_excl = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_excl.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "ranks",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_excl",
    see_also = {
      "MPI_Group_incl",
    },
    signature = "MPI_Group_excl(group, n, ranks, newgroup, ierror)",
    standard = "MPI-1.0",
    summary = "Build a group by removing a list of ranks from an existing group",
  },
  mpi_group_free = {
    binding_note = "mpi_f08 spells group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_free",
    see_also = {
      "MPI_Comm_group",
    },
    signature = "MPI_Group_free(group, ierror)",
    standard = "MPI-1.0",
    summary = "Release a group handle",
  },
  mpi_group_incl = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_incl.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "ranks",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_incl",
    see_also = {
      "MPI_Group_excl",
      "MPI_Comm_create",
    },
    signature = "MPI_Group_incl(group, n, ranks, newgroup, ierror)",
    standard = "MPI-1.0",
    summary = "Build a group from a list of ranks of an existing group",
  },
  mpi_group_intersection = {
    binding_note = "mpi_f08 spells group1 as type(MPI_Group), group2 as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_intersection.3.php",
    interface = {
      {
        intent = "in",
        name = "group1",
        type = "integer",
      },
      {
        intent = "in",
        name = "group2",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_intersection",
    signature = "MPI_Group_intersection(group1, group2, newgroup, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_GROUP_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_group_range_excl = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_range_excl.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(3, *)",
        intent = "in",
        name = "ranges",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_range_excl",
    signature = "MPI_Group_range_excl(group, n, ranges, newgroup, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_range_incl = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_range_incl.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(3, *)",
        intent = "in",
        name = "ranges",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_range_incl",
    signature = "MPI_Group_range_incl(group, n, ranges, newgroup, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_rank = {
    binding_note = "mpi_f08 spells group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_rank.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "rank",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_rank",
    see_also = {
      "MPI_Comm_group",
      "MPI_Comm_rank",
    },
    signature = "MPI_Group_rank(group, rank, ierror)",
    standard = "MPI-1.0",
    summary = "The calling process's rank within a group",
  },
  mpi_group_size = {
    binding_note = "mpi_f08 spells group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_size.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_size",
    see_also = {
      "MPI_Comm_group",
    },
    signature = "MPI_Group_size(group, size, ierror)",
    standard = "MPI-1.0",
    summary = "Number of processes in a group",
  },
  mpi_group_translate_ranks = {
    binding_note = "mpi_f08 spells group1 as type(MPI_Group) and group2 as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_translate_ranks.3.php",
    interface = {
      {
        intent = "in",
        name = "group1",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "ranks1",
        type = "integer",
      },
      {
        intent = "in",
        name = "group2",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "ranks2",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_translate_ranks",
    signature = "MPI_Group_translate_ranks(group1, n, ranks1, group2, ranks2, ierror)",
    standard = "MPI-1.0",
  },
  mpi_group_union = {
    binding_note = "mpi_f08 spells group1 as type(MPI_Group), group2 as type(MPI_Group) and newgroup as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Group_union.3.php",
    interface = {
      {
        intent = "in",
        name = "group1",
        type = "integer",
      },
      {
        intent = "in",
        name = "group2",
        type = "integer",
      },
      {
        intent = "out",
        name = "newgroup",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Group_union",
    signature = "MPI_Group_union(group1, group2, newgroup, ierror)",
    standard = "MPI-1.0",
  },
  mpi_host = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_HOST",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_iallgather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iallgather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iallgather",
    see_also = {
      "MPI_Allgather",
      "MPI_Wait",
    },
    signature = "MPI_Iallgather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking all-gather",
  },
  mpi_iallgatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iallgatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iallgatherv",
    signature = "MPI_Iallgatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_iallreduce = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iallreduce.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iallreduce",
    see_also = {
      "MPI_Allreduce",
      "MPI_Wait",
    },
    signature = "MPI_Iallreduce(sendbuf, recvbuf, count, datatype, op, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking all-reduce",
  },
  mpi_ialltoall = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ialltoall.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ialltoall",
    see_also = {
      "MPI_Alltoall",
      "MPI_Wait",
    },
    signature = "MPI_Ialltoall(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking all-to-all exchange",
  },
  mpi_ialltoallv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ialltoallv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ialltoallv",
    signature = "MPI_Ialltoallv(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ialltoallw = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ialltoallw.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ialltoallw",
    signature = "MPI_Ialltoallw(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ibarrier = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ibarrier.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ibarrier",
    see_also = {
      "MPI_Barrier",
      "MPI_Wait",
    },
    signature = "MPI_Ibarrier(comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking barrier: returns at once and completes through a request",
  },
  mpi_ibcast = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ibcast.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buffer",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ibcast",
    see_also = {
      "MPI_Bcast",
      "MPI_Wait",
    },
    signature = "MPI_Ibcast(buffer, count, datatype, root, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking broadcast",
  },
  mpi_ibsend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ibsend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ibsend",
    signature = "MPI_Ibsend(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_ident = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_IDENT",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_iexscan = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iexscan.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iexscan",
    signature = "MPI_Iexscan(sendbuf, recvbuf, count, datatype, op, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_igather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Igather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Igather",
    see_also = {
      "MPI_Gather",
      "MPI_Wait",
    },
    signature = "MPI_Igather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking gather to a root",
  },
  mpi_igatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Igatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Igatherv",
    signature = "MPI_Igatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, root, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_improbe = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), message as type(MPI_Message) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Improbe.3.php",
    interface = {
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "message",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Improbe",
    signature = "MPI_Improbe(source, tag, comm, flag, message, status, ierror)",
    standard = "MPI-3.0",
  },
  mpi_imrecv = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), message as type(MPI_Message) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Imrecv.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "inout",
        name = "message",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Imrecv",
    signature = "MPI_Imrecv(buf, count, datatype, message, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_in_place = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    description = "**MPI_IN_PLACE** replaces the send buffer of a collective and asks MPI to\n" ..
      "take the input from, and leave the result in, the receive buffer. It removes\n" ..
      "the second array a naive MPI_Allreduce needs, which matters when the buffer is\n" ..
      "large.\n" ..
      "\n" ..
      "The rules differ per routine -- for MPI_Reduce only the root passes it, for\n" ..
      "MPI_Allreduce every rank does -- and passing it on the wrong side is undefined\n" ..
      "behaviour rather than an error. Like MPI_STATUS_IGNORE it is a COMMON-block\n" ..
      "variable, so it must be in scope.",
    example = "  ! every rank: total = sum over ranks of total\n" ..
      "  call MPI_Allreduce(MPI_IN_PLACE, total, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_IN_PLACE",
    section = "Collectives",
    see_also = {
      "MPI_Allreduce",
      "MPI_Reduce",
      "MPI_Gather",
    },
    standard = "MPI-2.0",
    summary = "Pass as the send buffer of a collective to reduce in place",
    type = "integer",
  },
  mpi_ineighbor_allgather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ineighbor_allgather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ineighbor_allgather",
    signature = "MPI_Ineighbor_allgather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ineighbor_allgatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ineighbor_allgatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ineighbor_allgatherv",
    signature = "MPI_Ineighbor_allgatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ineighbor_alltoall = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ineighbor_alltoall.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ineighbor_alltoall",
    signature = "MPI_Ineighbor_alltoall(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ineighbor_alltoallv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ineighbor_alltoallv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ineighbor_alltoallv",
    signature = "MPI_Ineighbor_alltoallv(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ineighbor_alltoallw = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ineighbor_alltoallw.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ineighbor_alltoallw",
    signature = "MPI_Ineighbor_alltoallw(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_info_create = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_create.3.php",
    interface = {
      {
        intent = "out",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_create",
    signature = "MPI_Info_create(info, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_create_env = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_create_env.3.php",
    interface = {
      {
        intent = "out",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_create_env",
    signature = "MPI_Info_create_env(info, ierror)",
    standard = "MPI-4.0",
  },
  mpi_info_delete = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_delete.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_delete",
    signature = "MPI_Info_delete(info, key, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_dup = {
    binding_note = "mpi_f08 spells info as type(MPI_Info) and newinfo as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_dup.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "newinfo",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_dup",
    signature = "MPI_Info_dup(info, newinfo, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_env = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INFO_ENV",
    section = "mpif-handles.h",
    type = "integer",
    value = "1",
  },
  mpi_info_free = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_free",
    signature = "MPI_Info_free(info, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_get = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_get.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "valuelen",
        type = "integer",
      },
      {
        intent = "out",
        name = "value",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_get",
    signature = "MPI_Info_get(info, key, valuelen, value, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_get_nkeys = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_get_nkeys.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "nkeys",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_get_nkeys",
    signature = "MPI_Info_get_nkeys(info, nkeys, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_get_nthkey = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_get_nthkey.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "n",
        type = "integer",
      },
      {
        intent = "out",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_get_nthkey",
    signature = "MPI_Info_get_nthkey(info, n, key, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_get_string = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_get_string.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "inout",
        name = "buflen",
        type = "integer",
      },
      {
        intent = "out",
        name = "value",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_get_string",
    signature = "MPI_Info_get_string(info, key, buflen, value, flag, ierror)",
    standard = "MPI-4.0",
  },
  mpi_info_get_valuelen = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_get_valuelen.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "valuelen",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_get_valuelen",
    signature = "MPI_Info_get_valuelen(info, key, valuelen, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_info_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INFO_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_info_set = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Info_set.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "key",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "value",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Info_set",
    signature = "MPI_Info_set(info, key, value, ierror)",
    standard = "MPI-2.0",
  },
  mpi_init = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    description = "**MPI_Init** initializes the MPI execution environment. This function must\n" ..
      "be called before any other MPI function (except MPI_Initialized and\n" ..
      "MPI_Get_library_version). It establishes the MPI execution environment,\n" ..
      "including setting up internal data structures, establishing communication\n" ..
      "with other MPI processes, and preparing for message passing operations.",
    example = "program demo_mpi_init\n" ..
      "  use mpi_f08\n" ..
      "  implicit none\n" ..
      "  integer :: rank, nprocs, ierr\n" ..
      "\n" ..
      "  ! Initialize MPI environment\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  if (ierr /= MPI_SUCCESS) then\n" ..
      "    print *, 'Error initializing MPI'\n" ..
      "    stop 1\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Get process rank and total number of processes\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  print '(A,I0,A,I0)', 'Hello from process ', rank, ' of ', nprocs\n" ..
      "\n" ..
      "  ! Finalize MPI environment\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_init",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Init.3.php",
    interface = {
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Init",
    params = {
      ierror = "Integer error code. Returns MPI_SUCCESS (0) on successful initialization. In the mpi_f08 module, this argument is optional. If omitted and an error occurs, the program will abort.",
    },
    result = "After successful completion, the MPI environment is initialized and ready\n" ..
      "for use. The program can then call MPI_Comm_rank, MPI_Comm_size, and other\n" ..
      "MPI routines. The predefined communicator MPI_COMM_WORLD becomes available,\n" ..
      "containing all processes in the MPI job.",
    see_also = {
      "MPI_Finalize",
      "MPI_Initialized",
      "MPI_Comm_rank",
      "MPI_Comm_size",
      "MPI_Abort",
    },
    signature = "MPI_Init(ierror)",
    standard = "MPI-1.0",
    summary = "Initialize the MPI execution environment",
  },
  mpi_init_thread = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    description = "**MPI_Init_thread** initializes MPI and negotiates thread support. It is what\n" ..
      "an MPI + OpenMP program must call instead of MPI_Init.\n" ..
      "\n" ..
      "The critical detail is that **provided** may come back lower than\n" ..
      "**required** and the call still succeeds. Code that asks for\n" ..
      "MPI_THREAD_MULTIPLE and does not check what it got will make concurrent MPI\n" ..
      "calls against an implementation that cannot support them, and fail\n" ..
      "intermittently under load. Check, and degrade deliberately.\n" ..
      "\n" ..
      "The levels, in increasing order: SINGLE (one thread), FUNNELED (only the\n" ..
      "thread that called this may call MPI), SERIALIZED (any one thread at a time),\n" ..
      "MULTIPLE (unrestricted).",
    example = "  call MPI_Init_thread(MPI_THREAD_FUNNELED, provided, ierr)\n" ..
      "  if (provided < MPI_THREAD_FUNNELED) then\n" ..
      "     write(*,*) 'insufficient MPI thread support'\n" ..
      "     call MPI_Abort(MPI_COMM_WORLD, 1, ierr)\n" ..
      "  end if",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Init_thread.3.php",
    interface = {
      {
        intent = "in",
        name = "required",
        type = "integer",
      },
      {
        intent = "out",
        name = "provided",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Init_thread",
    params = {
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      provided = "Level actually granted -- may be lower than **required**.",
      required = "Desired level of thread support.",
    },
    result = "MPI is initialized; **provided** states the thread support actually available.",
    see_also = {
      "MPI_Init",
      "omp_get_thread_num",
    },
    signature = "MPI_Init_thread(required, provided, ierror)",
    standard = "MPI-2.0",
    summary = "Initialize MPI with a requested level of thread support",
  },
  mpi_initialized = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Initialized.3.php",
    interface = {
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Initialized",
    see_also = {
      "MPI_Init",
      "MPI_Finalized",
    },
    signature = "MPI_Initialized(flag, ierror)",
    standard = "MPI-1.0",
    summary = "Test whether MPI_Init has already been called",
  },
  mpi_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "39",
  },
  mpi_int16_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INT16_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "60",
  },
  mpi_int32_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INT32_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "62",
  },
  mpi_int64_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INT64_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "64",
  },
  mpi_int8_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INT8_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "58",
  },
  mpi_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_INTEGER** is the datatype handle matching the default Fortran INTEGER.\n" ..
      "\n" ..
      "It follows the compiler's default integer kind, so a build using\n" ..
      "`-fdefault-integer-8` changes what it must be paired with. Explicit kinds have\n" ..
      "their own handles (MPI_INTEGER4, MPI_INTEGER8).",
    example = "  call MPI_Bcast(n, 1, MPI_INTEGER, 0, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER",
    section = "Datatypes",
    see_also = {
      "MPI_DOUBLE_PRECISION",
      "MPI_REAL",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for Fortran INTEGER",
    type = "integer",
    value = "7",
  },
  mpi_integer1 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER1",
    section = "mpif-handles.h",
    type = "integer",
    value = "8",
  },
  mpi_integer16 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER16",
    section = "mpif-handles.h",
    type = "integer",
    value = "12",
  },
  mpi_integer2 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER2",
    section = "mpif-handles.h",
    type = "integer",
    value = "9",
  },
  mpi_integer4 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER4",
    section = "mpif-handles.h",
    type = "integer",
    value = "10",
  },
  mpi_integer8 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER8",
    section = "mpif-handles.h",
    type = "integer",
    value = "11",
  },
  mpi_integer_kind = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_INTEGER_KIND",
    section = "mpif-config.h",
    type = "integer",
    value = "4",
  },
  mpi_intercomm_create = {
    binding_note = "mpi_f08 spells local_comm as type(MPI_Comm), peer_comm as type(MPI_Comm) and newintercomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Intercomm_create.3.php",
    interface = {
      {
        intent = "in",
        name = "local_comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "local_leader",
        type = "integer",
      },
      {
        intent = "in",
        name = "bridge_comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "remote_leader",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "out",
        name = "newintercomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Intercomm_create",
    signature = "MPI_Intercomm_create(local_comm, local_leader, bridge_comm, remote_leader, tag, newintercomm, ierror)",
    standard = "MPI-1.0",
  },
  mpi_intercomm_merge = {
    binding_note = "mpi_f08 spells intercomm as type(MPI_Comm) and newintracomm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Intercomm_merge.3.php",
    interface = {
      {
        intent = "in",
        name = "intercomm",
        type = "integer",
      },
      {
        intent = "in",
        name = "high",
        type = "logical",
      },
      {
        intent = "out",
        name = "newintracomm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Intercomm_merge",
    signature = "MPI_Intercomm_merge(intercomm, high, newintracomm, ierror)",
    standard = "MPI-1.0",
  },
  mpi_io = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_IO",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_iprobe = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and status as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Iprobe** is the non-blocking MPI_Probe: it returns at once, setting\n" ..
      "**flag** to say whether a matching message is waiting. Reading **status**\n" ..
      "when **flag** is .FALSE. gives garbage.\n" ..
      "\n" ..
      "A tight polling loop on MPI_Iprobe burns a core doing nothing; prefer\n" ..
      "MPI_Probe when there is nothing else to do.",
    example = "  logical :: flag\n" ..
      "  call MPI_Iprobe(MPI_ANY_SOURCE, tag, MPI_COMM_WORLD, flag, status, ierr)\n" ..
      "  if (flag) then\n" ..
      "     call MPI_Get_count(status, MPI_INTEGER, n, ierr)\n" ..
      "     call MPI_Recv(ibuf, n, MPI_INTEGER, status(MPI_SOURCE), &\n" ..
      "                   status(MPI_TAG), MPI_COMM_WORLD, status, ierr)\n" ..
      "  end if",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iprobe.3.php",
    interface = {
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iprobe",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      flag = ".TRUE. when a matching message is available.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      source = "Rank to probe for, or MPI_ANY_SOURCE.",
      status = "Valid only when **flag** is .TRUE.",
      tag = "Tag to match, or MPI_ANY_TAG.",
    },
    result = "**flag** reports availability; **status** describes the message when it is .TRUE.",
    see_also = {
      "MPI_Probe",
      "MPI_Get_count",
    },
    signature = "MPI_Iprobe(source, tag, comm, flag, status, ierror)",
    standard = "MPI-1.0",
    summary = "Check for a message without blocking",
  },
  mpi_irecv = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    description = "**MPI_Irecv** posts a receive and returns at once. The buffer holds nothing\n" ..
      "useful until MPI_Wait or MPI_Test reports completion, and reading it early is\n" ..
      "the classic non-blocking bug -- it usually appears to work, because the\n" ..
      "message often has arrived.\n" ..
      "\n" ..
      "Note the missing status: unlike MPI_Recv, there is nowhere here to learn the\n" ..
      "actual source, tag or length. That information comes from the status filled\n" ..
      "in by MPI_Wait, which is what MPI_Get_count must then be given.",
    example = "  integer :: req, status(MPI_STATUS_SIZE), nrecv\n" ..
      "\n" ..
      "  call MPI_Irecv(buf, LPMX, MPI_DOUBLE_PRECISION, MPI_ANY_SOURCE, &\n" ..
      "                 tag, MPI_COMM_WORLD, req, ierr)\n" ..
      "  call do_other_work()\n" ..
      "  call MPI_Wait(req, status, ierr)              ! status arrives HERE\n" ..
      "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, nrecv, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Irecv.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Irecv",
    params = {
      buf = "Receive buffer. Do not read until the request completes.",
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      count = "Buffer CAPACITY in elements -- an upper bound, not the message size.",
      datatype = "MPI datatype of each element.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      request = "Returns the handle used to complete the operation.",
      source = "Rank to receive from, or MPI_ANY_SOURCE.",
      tag = "Message tag to match, or MPI_ANY_TAG.",
    },
    result = "**request** identifies the pending receive; **buf** is not yet valid.",
    see_also = {
      "MPI_Isend",
      "MPI_Wait",
      "MPI_Get_count",
      "MPI_Recv",
    },
    signature = "MPI_Irecv(buf, count, datatype, source, tag, comm, request, ierror)",
    standard = "MPI-1.0",
    summary = "Begin a non-blocking receive",
  },
  mpi_ireduce = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ireduce.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ireduce",
    see_also = {
      "MPI_Reduce",
      "MPI_Wait",
    },
    signature = "MPI_Ireduce(sendbuf, recvbuf, count, datatype, op, root, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking reduction to a root",
  },
  mpi_ireduce_scatter = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ireduce_scatter.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ireduce_scatter",
    signature = "MPI_Ireduce_scatter(sendbuf, recvbuf, recvcounts, datatype, op, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_ireduce_scatter_block = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ireduce_scatter_block.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ireduce_scatter_block",
    signature = "MPI_Ireduce_scatter_block(sendbuf, recvbuf, recvcount, datatype, op, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_irsend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Irsend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Irsend",
    signature = "MPI_Irsend(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_is_thread_main = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Is_thread_main.3.php",
    interface = {
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Is_thread_main",
    see_also = {
      "MPI_Init_thread",
      "MPI_Query_thread",
    },
    signature = "MPI_Is_thread_main(flag, ierror)",
    standard = "MPI-2.0",
    summary = "Test whether the calling thread is the one that called MPI_Init",
  },
  mpi_iscan = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iscan.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iscan",
    signature = "MPI_Iscan(sendbuf, recvbuf, count, datatype, op, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_iscatter = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iscatter.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iscatter",
    see_also = {
      "MPI_Scatter",
      "MPI_Wait",
    },
    signature = "MPI_Iscatter(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, request, ierror)",
    standard = "MPI-3.0",
    summary = "Nonblocking scatter from a root",
  },
  mpi_iscatterv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Iscatterv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Iscatterv",
    signature = "MPI_Iscatterv(sendbuf, sendcounts, displs, sendtype, recvbuf, recvcount, recvtype, root, comm, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_isend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    description = "**MPI_Isend** starts a send and returns at once, handing back a **request**\n" ..
      "handle. The send is not finished until MPI_Wait or MPI_Test says it is.\n" ..
      "\n" ..
      "Two rules make the difference between this and MPI_Send. **buf** may not be\n" ..
      "touched -- read or written -- until completion, because MPI may still be\n" ..
      "reading it; and the request must be completed, or the resources leak and the\n" ..
      "message may never be delivered.\n" ..
      "\n" ..
      "Its value is overlap: pair MPI_Isend with MPI_Irecv, do interior work, then\n" ..
      "wait. The usual deadlock of two ranks calling MPI_Send to each other\n" ..
      "simultaneously also disappears.",
    example = "  call MPI_Irecv(halo_in,  n, MPI_DOUBLE_PRECISION, left,  1, &\n" ..
      "                 MPI_COMM_WORLD, req(1), ierr)\n" ..
      "  call MPI_Isend(halo_out, n, MPI_DOUBLE_PRECISION, right, 1, &\n" ..
      "                 MPI_COMM_WORLD, req(2), ierr)\n" ..
      "\n" ..
      "  call update_interior()          ! overlap with communication\n" ..
      "\n" ..
      "  call MPI_Waitall(2, req, stats, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Isend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Isend",
    params = {
      buf = "Send buffer. Do not modify until the request completes.",
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      count = "Number of elements to send.",
      datatype = "MPI datatype of each element.",
      dest = "Rank of the destination process in **comm**.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      request = "Returns the handle used to complete the operation.",
      tag = "Message tag, matched by the receiver.",
    },
    result = "**request** identifies the pending send; the transfer is not complete on return.",
    see_also = {
      "MPI_Irecv",
      "MPI_Wait",
      "MPI_Waitall",
      "MPI_Send",
    },
    signature = "MPI_Isend(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
    summary = "Begin a non-blocking send",
  },
  mpi_isendrecv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Isendrecv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtag",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Isendrecv",
    signature = "MPI_Isendrecv(sendbuf, sendcount, sendtype, dest, sendtag, recvbuf, recvcount, recvtype, source, recvtag, comm, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_isendrecv_replace = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Isendrecv_replace.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Isendrecv_replace",
    signature = "MPI_Isendrecv_replace(buf, count, datatype, dest, sendtag, source, recvtag, comm, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_issend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Issend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Issend",
    signature = "MPI_Issend(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_keyval_invalid = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_KEYVAL_INVALID",
    section = "mpif-constants.h",
    type = "integer",
    value = "-1",
  },
  mpi_land = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_LAND** reduces LOGICAL values with .AND., which is how a global\n" ..
      "convergence test is written: the loop ends only when every rank agrees.\n" ..
      "\n" ..
      "Use MPI_Allreduce rather than MPI_Reduce for this -- a decision known only to\n" ..
      "the root is not usable as a loop condition, and ranks that leave the loop at\n" ..
      "different iterations deadlock in the next collective.",
    example = "  call MPI_Allreduce(done_local, done, 1, MPI_LOGICAL, &\n" ..
      "                     MPI_LAND, MPI_COMM_WORLD, ierr)\n" ..
      "  if (done) exit",
    kind = "constant",
    module = "mpi",
    name = "MPI_LAND",
    section = "Reduction operations",
    see_also = {
      "MPI_LOR",
      "MPI_LOGICAL",
      "MPI_Allreduce",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: logical AND",
    type = "integer",
    value = "5",
  },
  mpi_lastusedcode = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LASTUSEDCODE",
    section = "mpif-constants.h",
    type = "integer",
    value = "5",
  },
  mpi_lb = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LB",
    section = "mpif-handles.h",
    type = "integer",
    value = "4",
  },
  mpi_lock_exclusive = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOCK_EXCLUSIVE",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_lock_shared = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOCK_SHARED",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_logical = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_LOGICAL** is the datatype handle for Fortran LOGICAL. It pairs with\n" ..
      "the logical reduction operations MPI_LAND, MPI_LOR and MPI_LXOR.\n" ..
      "\n" ..
      "The bit pattern of .TRUE. is compiler-defined, so a LOGICAL must never be\n" ..
      "sent as MPI_INTEGER between differently built executables.",
    example = "  call MPI_Allreduce(converged_local, converged, 1, MPI_LOGICAL, &\n" ..
      "                     MPI_LAND, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOGICAL",
    section = "Datatypes",
    see_also = {
      "MPI_SUM",
      "MPI_Allreduce",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for Fortran LOGICAL",
    type = "integer",
    value = "6",
  },
  mpi_logical1 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOGICAL1",
    section = "mpif-handles.h",
    type = "integer",
    value = "29",
  },
  mpi_logical2 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOGICAL2",
    section = "mpif-handles.h",
    type = "integer",
    value = "30",
  },
  mpi_logical4 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOGICAL4",
    section = "mpif-handles.h",
    type = "integer",
    value = "31",
  },
  mpi_logical8 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOGICAL8",
    section = "mpif-handles.h",
    type = "integer",
    value = "32",
  },
  mpi_long = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG",
    section = "mpif-handles.h",
    type = "integer",
    value = "41",
  },
  mpi_long_double = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG_DOUBLE",
    section = "mpif-handles.h",
    type = "integer",
    value = "47",
  },
  mpi_long_double_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG_DOUBLE_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "50",
  },
  mpi_long_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "51",
  },
  mpi_long_long = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG_LONG",
    section = "mpif-handles.h",
    type = "integer",
    value = "43",
  },
  mpi_long_long_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LONG_LONG_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "43",
  },
  mpi_lookup_name = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Lookup_name.3.php",
    interface = {
      {
        intent = "in",
        name = "service_name",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Lookup_name",
    signature = "MPI_Lookup_name(service_name, info, port_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_lor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_LOR** reduces LOGICAL values with .OR. -- true on every rank when any\n" ..
      "rank contributed true. The natural pairing is a global error flag: any rank\n" ..
      "detecting a problem makes all ranks aware of it, so they can shut down\n" ..
      "together rather than deadlocking.",
    example = "  call MPI_Allreduce(bad_local, any_bad, 1, MPI_LOGICAL, &\n" ..
      "                     MPI_LOR, MPI_COMM_WORLD, ierr)\n" ..
      "  if (any_bad) call MPI_Abort(MPI_COMM_WORLD, 3, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LOR",
    section = "Reduction operations",
    see_also = {
      "MPI_LAND",
      "MPI_LOGICAL",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: logical OR",
    type = "integer",
    value = "7",
  },
  mpi_lxor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_LXOR",
    section = "mpif-handles.h",
    type = "integer",
    value = "9",
  },
  mpi_max = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_MAX** reduces by taking the elementwise maximum. Unlike MPI_SUM it is\n" ..
      "exact and order-independent for floating point, so it reproduces across runs\n" ..
      "and process counts.\n" ..
      "\n" ..
      "To learn WHICH rank held the maximum, use MPI_MAXLOC with a pair datatype\n" ..
      "such as MPI_2DOUBLE_PRECISION.",
    example = "  call MPI_Allreduce(vlocal, vmax, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_MAX, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX",
    section = "Reduction operations",
    see_also = {
      "MPI_MIN",
      "MPI_SUM",
      "MPI_MAXLOC",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: maximum",
    type = "integer",
    value = "1",
  },
  mpi_max_datarep_string = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_DATAREP_STRING",
    section = "mpif-config.h",
    type = "integer",
    value = "127",
  },
  mpi_max_error_string = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_ERROR_STRING",
    section = "mpif-config.h",
    type = "integer",
    value = "255",
  },
  mpi_max_info_key = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_INFO_KEY",
    section = "mpif-config.h",
    type = "integer",
    value = "35",
  },
  mpi_max_info_val = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_INFO_VAL",
    section = "mpif-config.h",
    type = "integer",
    value = "255",
  },
  mpi_max_library_version_string = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_LIBRARY_VERSION_STRING",
    section = "mpif-config.h",
    type = "integer",
    value = "255",
  },
  mpi_max_object_name = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_OBJECT_NAME",
    section = "mpif-config.h",
    type = "integer",
    value = "63",
  },
  mpi_max_port_name = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_PORT_NAME",
    section = "mpif-config.h",
    type = "integer",
    value = "1023",
  },
  mpi_max_processor_name = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_PROCESSOR_NAME",
    section = "mpif-config.h",
    type = "integer",
    value = "255",
  },
  mpi_max_pset_name_len = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_PSET_NAME_LEN",
    section = "mpif-config.h",
    type = "integer",
    value = "511",
  },
  mpi_max_stringtag_len = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAX_STRINGTAG_LEN",
    section = "mpif-config.h",
    type = "integer",
    value = "1023",
  },
  mpi_maxloc = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_MAXLOC** returns the maximum together with the rank that held it,\n" ..
      "using a pair datatype exactly as MPI_MINLOC does. Ties resolve to the lowest\n" ..
      "identifier.",
    example = "  call MPI_Allreduce(inpair, outpair, 1, MPI_2DOUBLE_PRECISION, &\n" ..
      "                     MPI_MAXLOC, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MAXLOC",
    section = "Reduction operations",
    see_also = {
      "MPI_MINLOC",
      "MPI_MAX",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: maximum and its location",
    type = "integer",
    value = "11",
  },
  mpi_message_no_proc = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MESSAGE_NO_PROC",
    section = "mpif-handles.h",
    type = "integer",
    value = "1",
  },
  mpi_message_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MESSAGE_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_min = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_MIN** reduces by taking the elementwise minimum. Like MPI_MAX it is\n" ..
      "exact and order-independent. Use MPI_MINLOC to also learn which rank held\n" ..
      "the minimum.",
    example = "  call MPI_Allreduce(dtlocal, dtmin, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_MIN, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MIN",
    section = "Reduction operations",
    see_also = {
      "MPI_MAX",
      "MPI_MINLOC",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: minimum",
    type = "integer",
    value = "2",
  },
  mpi_minloc = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_MINLOC** returns both the minimum value and the rank that held it, so\n" ..
      "the buffer is a PAIR type -- MPI_2DOUBLE_PRECISION, MPI_2INTEGER or\n" ..
      "MPI_2REAL -- and each contribution is two elements: the value followed by an\n" ..
      "integer identifier, conventionally the rank.\n" ..
      "\n" ..
      "Passing a plain MPI_DOUBLE_PRECISION buffer here is a common error; the\n" ..
      "reduction then reads past the value it was given.",
    example = "  real(8) :: inpair(2), outpair(2)\n" ..
      "  inpair(1) = vlocal\n" ..
      "  inpair(2) = real(rank, 8)\n" ..
      "  call MPI_Allreduce(inpair, outpair, 1, MPI_2DOUBLE_PRECISION, &\n" ..
      "                     MPI_MINLOC, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MINLOC",
    section = "Reduction operations",
    see_also = {
      "MPI_MAXLOC",
      "MPI_MIN",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: minimum and its location",
    type = "integer",
    value = "12",
  },
  mpi_mode_append = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_APPEND",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "128",
  },
  mpi_mode_create = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_CREATE",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_mode_delete_on_close = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_DELETE_ON_CLOSE",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "16",
  },
  mpi_mode_excl = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_EXCL",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "64",
  },
  mpi_mode_nocheck = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_NOCHECK",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_mode_noprecede = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_NOPRECEDE",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_mode_noput = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_NOPUT",
    section = "mpif-constants.h",
    type = "integer",
    value = "4",
  },
  mpi_mode_nostore = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_NOSTORE",
    section = "mpif-constants.h",
    type = "integer",
    value = "8",
  },
  mpi_mode_nosucceed = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_NOSUCCEED",
    section = "mpif-constants.h",
    type = "integer",
    value = "16",
  },
  mpi_mode_rdonly = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_RDONLY",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_mode_rdwr = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_RDWR",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "8",
  },
  mpi_mode_sequential = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_SEQUENTIAL",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "256",
  },
  mpi_mode_unique_open = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_UNIQUE_OPEN",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "32",
  },
  mpi_mode_wronly = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_MODE_WRONLY",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "4",
  },
  mpi_mprobe = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm), message as type(MPI_Message) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Mprobe.3.php",
    interface = {
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "message",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Mprobe",
    signature = "MPI_Mprobe(source, tag, comm, message, status, ierror)",
    standard = "MPI-3.0",
  },
  mpi_mrecv = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), message as type(MPI_Message) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Mrecv.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "inout",
        name = "message",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Mrecv",
    signature = "MPI_Mrecv(buf, count, datatype, message, status, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_allgather = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_allgather.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_allgather",
    signature = "MPI_Neighbor_allgather(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_allgather_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_allgather_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_allgather_init",
    signature = "MPI_Neighbor_allgather_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_neighbor_allgatherv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_allgatherv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_allgatherv",
    signature = "MPI_Neighbor_allgatherv(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_allgatherv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_allgatherv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_allgatherv_init",
    signature = "MPI_Neighbor_allgatherv_init(sendbuf, sendcount, sendtype, recvbuf, recvcounts, displs, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_neighbor_alltoall = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoall.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoall",
    signature = "MPI_Neighbor_alltoall(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_alltoall_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoall_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoall_init",
    signature = "MPI_Neighbor_alltoall_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_neighbor_alltoallv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoallv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoallv",
    signature = "MPI_Neighbor_alltoallv(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_alltoallv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoallv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoallv_init",
    signature = "MPI_Neighbor_alltoallv_init(sendbuf, sendcounts, sdispls, sendtype, recvbuf, recvcounts, rdispls, recvtype, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_neighbor_alltoallw = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoallw.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoallw",
    signature = "MPI_Neighbor_alltoallw(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, ierror)",
    standard = "MPI-3.0",
  },
  mpi_neighbor_alltoallw_init = {
    binding_note = "mpi_f08 spells sendtypes as type(MPI_Datatype), recvtypes as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Neighbor_alltoallw_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendtypes",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "rdispls",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvtypes",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Neighbor_alltoallw_init",
    signature = "MPI_Neighbor_alltoallw_init(sendbuf, sendcounts, sdispls, sendtypes, recvbuf, recvcounts, rdispls, recvtypes, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_no_op = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_NO_OP",
    section = "mpif-handles.h",
    type = "integer",
    value = "14",
  },
  mpi_null_copy_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_NULL_COPY_FN.3.php",
    interface = {
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer",
      },
      {
        name = "attribute_val_in",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_NULL_COPY_FN",
    signature = "MPI_NULL_COPY_FN(comm, comm_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-1.0",
  },
  mpi_null_delete_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_NULL_DELETE_FN.3.php",
    interface = {
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "comm_keyval",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_NULL_DELETE_FN",
    signature = "MPI_NULL_DELETE_FN(comm, comm_keyval, attribute_val_out, extra_state, ierr)",
    standard = "MPI-1.0",
  },
  mpi_offset = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_OFFSET",
    section = "mpif-handles.h",
    type = "integer",
    value = "67",
  },
  mpi_offset_kind = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_OFFSET_KIND",
    section = "mpif-config.h",
    type = "integer",
    value = "8",
  },
  mpi_op_commutative = {
    binding_note = "mpi_f08 spells op as type(MPI_Op); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Op_commutative.3.php",
    interface = {
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "out",
        name = "commute",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Op_commutative",
    signature = "MPI_Op_commutative(op, commute, ierror)",
    standard = "MPI-2.2",
  },
  mpi_op_create = {
    binding_note = "mpi_f08 spells op as type(MPI_Op); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Op_create.3.php",
    interface = {
      {
        name = "function",
        type = "external",
      },
      {
        intent = "in",
        name = "commute",
        type = "logical",
      },
      {
        intent = "out",
        name = "op",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Op_create",
    see_also = {
      "MPI_Reduce",
      "MPI_Op_free",
    },
    signature = "MPI_Op_create(function, commute, op, ierror)",
    standard = "MPI-1.0",
    summary = "Register a user-defined reduction operation",
  },
  mpi_op_free = {
    binding_note = "mpi_f08 spells op as type(MPI_Op); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Op_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "op",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Op_free",
    see_also = {
      "MPI_Op_create",
    },
    signature = "MPI_Op_free(op, ierror)",
    standard = "MPI-1.0",
    summary = "Release a user-defined reduction operation",
  },
  mpi_op_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_OP_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_open_port = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Open_port.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Open_port",
    signature = "MPI_Open_port(info, port_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_order_c = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ORDER_C",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_order_fortran = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ORDER_FORTRAN",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_pack = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pack.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "inbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "outbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "outsize",
        type = "integer",
      },
      {
        intent = "inout",
        name = "position",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pack",
    see_also = {
      "MPI_Unpack",
      "MPI_Pack_size",
    },
    signature = "MPI_Pack(inbuf, incount, datatype, outbuf, outsize, position, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Pack data into a contiguous buffer for MPI_PACKED transmission",
  },
  mpi_pack_external = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pack_external.3.php",
    interface = {
      {
        intent = "in",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "inbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "outbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "outsize",
        type = "integer(8)",
      },
      {
        intent = "inout",
        name = "position",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pack_external",
    signature = "MPI_Pack_external(datarep, inbuf, incount, datatype, outbuf, outsize, position, ierror)",
    standard = "MPI-2.0",
  },
  mpi_pack_external_size = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pack_external_size.3.php",
    interface = {
      {
        intent = "in",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pack_external_size",
    signature = "MPI_Pack_external_size(datarep, incount, datatype, size, ierror)",
    standard = "MPI-2.0",
  },
  mpi_pack_size = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pack_size.3.php",
    interface = {
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pack_size",
    see_also = {
      "MPI_Pack",
    },
    signature = "MPI_Pack_size(incount, datatype, comm, size, ierror)",
    standard = "MPI-1.0",
    summary = "Upper bound on the space MPI_Pack needs for a message",
  },
  mpi_packed = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_PACKED",
    section = "Datatypes",
    standard = "MPI-1.0",
    type = "integer",
    value = "2",
  },
  mpi_parrived = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Parrived.3.php",
    interface = {
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "in",
        name = "partition",
        type = "integer",
      },
      {
        intent = "in",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Parrived",
    signature = "MPI_Parrived(request, partition, flag, ierror)",
    standard = "MPI-4.0",
  },
  mpi_pcontrol = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pcontrol.3.php",
    interface = {
      {
        intent = "in",
        name = "level",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pcontrol",
    signature = "MPI_Pcontrol(level)",
    standard = "MPI-1.0",
    summary = "Hint to a profiling layer; the MPI library itself may ignore it",
  },
  mpi_pready = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pready.3.php",
    interface = {
      {
        intent = "in",
        name = "partition",
        type = "integer",
      },
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pready",
    signature = "MPI_Pready(partition, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_pready_list = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pready_list.3.php",
    interface = {
      {
        intent = "in",
        name = "length",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "partitions",
        type = "integer",
      },
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pready_list",
    signature = "MPI_Pready_list(length, partitions, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_pready_range = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Pready_range.3.php",
    interface = {
      {
        intent = "in",
        name = "partition_low",
        type = "integer",
      },
      {
        intent = "in",
        name = "partition_high",
        type = "integer",
      },
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Pready_range",
    signature = "MPI_Pready_range(partition_low, partition_high, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_precv_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Precv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "partitions",
        type = "integer",
      },
      {
        intent = "in",
        name = "count",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Precv_init",
    signature = "MPI_Precv_init(buf, partitions, count, datatype, dest, tag, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_probe = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm) and status as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Probe** blocks until a matching message is ready, and fills in\n" ..
      "**status** describing it -- without receiving it. Combined with\n" ..
      "MPI_Get_count, that is how a receiver sizes an allocatable buffer for a\n" ..
      "message whose length it does not know in advance.\n" ..
      "\n" ..
      "The message stays in the queue, so a matching MPI_Recv must follow. Using\n" ..
      "MPI_ANY_SOURCE in both, without noting status(MPI_SOURCE) and receiving from\n" ..
      "exactly that rank, is a race: a different message may match the receive.",
    example = "  call MPI_Probe(MPI_ANY_SOURCE, tag, MPI_COMM_WORLD, status, ierr)\n" ..
      "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, n, ierr)\n" ..
      "  allocate(buf(n))\n" ..
      "  ! receive from THAT rank, not MPI_ANY_SOURCE again\n" ..
      "  call MPI_Recv(buf, n, MPI_DOUBLE_PRECISION, status(MPI_SOURCE), &\n" ..
      "                status(MPI_TAG), MPI_COMM_WORLD, status, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Probe.3.php",
    interface = {
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Probe",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      source = "Rank to probe for, or MPI_ANY_SOURCE.",
      status = "Describes the pending message: MPI_SOURCE, MPI_TAG and, via MPI_Get_count, its length.",
      tag = "Tag to match, or MPI_ANY_TAG.",
    },
    result = "**status** describes a message that is now guaranteed receivable.",
    see_also = {
      "MPI_Iprobe",
      "MPI_Get_count",
      "MPI_Recv",
    },
    signature = "MPI_Probe(source, tag, comm, status, ierror)",
    standard = "MPI-1.0",
    summary = "Wait for a message and inspect it without receiving",
  },
  mpi_proc_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_PROC_NULL** is the null process. A send to it returns immediately and\n" ..
      "delivers nothing; a receive from it returns immediately, leaves the buffer\n" ..
      "untouched, and reports source MPI_PROC_NULL, tag MPI_ANY_TAG and count 0.\n" ..
      "\n" ..
      "That is what makes it valuable: the edges of a halo exchange need no special\n" ..
      "case. MPI_Cart_shift already returns MPI_PROC_NULL for a neighbour that falls\n" ..
      "off a non-periodic grid, so the same MPI_Sendrecv runs on interior and\n" ..
      "boundary ranks alike.",
    example = "  call MPI_Cart_shift(cart, 0, 1, left, right, ierr)\n" ..
      "  ! left or right may be MPI_PROC_NULL at the grid edge -- no branch needed\n" ..
      "  call MPI_Sendrecv(out, n, MPI_DOUBLE_PRECISION, right, 1, &\n" ..
      "                    in,  n, MPI_DOUBLE_PRECISION, left,  1, &\n" ..
      "                    cart, status, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_PROC_NULL",
    section = "Ranks",
    see_also = {
      "MPI_Cart_shift",
      "MPI_ANY_SOURCE",
      "MPI_Sendrecv",
    },
    standard = "MPI-1.0",
    summary = "A rank that may be used as a source or destination and does nothing",
    type = "integer",
    value = "-2",
  },
  mpi_prod = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_PROD** reduces by elementwise multiplication. Like MPI_SUM it is\n" ..
      "order-dependent in floating point, and it overflows far faster -- a product\n" ..
      "over many ranks is usually better computed as a sum of logarithms.",
    example = "  call MPI_Allreduce(plocal, ptotal, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_PROD, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_PROD",
    section = "Reduction operations",
    see_also = {
      "MPI_SUM",
      "MPI_Allreduce",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: product",
    type = "integer",
    value = "4",
  },
  mpi_psend_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Psend_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "partitions",
        type = "integer",
      },
      {
        intent = "in",
        name = "count",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Psend_init",
    signature = "MPI_Psend_init(buf, partitions, count, datatype, dest, tag, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_publish_name = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Publish_name.3.php",
    interface = {
      {
        intent = "in",
        name = "service_name",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Publish_name",
    signature = "MPI_Publish_name(service_name, info, port_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_put = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Put.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Put",
    see_also = {
      "MPI_Get",
      "MPI_Win_fence",
    },
    signature = "MPI_Put(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, win, ierror)",
    standard = "MPI-2.0",
    summary = "Write into another rank's window, one-sided",
  },
  mpi_query_thread = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Query_thread.3.php",
    interface = {
      {
        intent = "out",
        name = "provided",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Query_thread",
    see_also = {
      "MPI_Init_thread",
      "MPI_Is_thread_main",
    },
    signature = "MPI_Query_thread(provided, ierror)",
    standard = "MPI-2.0",
    summary = "The level of thread support the MPI library actually provided",
  },
  mpi_raccumulate = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), op as type(MPI_Op), win as type(MPI_Win) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Raccumulate.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Raccumulate",
    signature = "MPI_Raccumulate(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, op, win, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_real = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_REAL** is the datatype handle for the default Fortran REAL, i.e.\n" ..
      "single precision.\n" ..
      "\n" ..
      "The most damaging datatype mistake in Fortran MPI is using it for a REAL*8\n" ..
      "array. Nothing diagnoses it: the compiler cannot see the association and MPI\n" ..
      "trusts the handle. Half the bytes move and the data is silently wrong. For\n" ..
      "REAL*8 the handle is MPI_DOUBLE_PRECISION.",
    example = "  real :: x(n)                                  ! single precision\n" ..
      "  call MPI_Bcast(x, n, MPI_REAL, 0, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REAL",
    section = "Datatypes",
    see_also = {
      "MPI_DOUBLE_PRECISION",
      "MPI_INTEGER",
    },
    standard = "MPI-1.0",
    summary = "Datatype handle for Fortran REAL",
    type = "integer",
    value = "13",
  },
  mpi_real16 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REAL16",
    section = "mpif-handles.h",
    type = "integer",
    value = "16",
  },
  mpi_real2 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REAL2",
    section = "mpif-handles.h",
    type = "integer",
    value = "28",
  },
  mpi_real4 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REAL4",
    section = "mpif-handles.h",
    type = "integer",
    value = "14",
  },
  mpi_real8 = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REAL8",
    section = "mpif-handles.h",
    type = "integer",
    value = "15",
  },
  mpi_recv = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and status as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Recv** performs a standard-mode blocking receive operation. It blocks\n" ..
      "until the receive buffer contains the newly received message from the\n" ..
      "specified source. The actual length of the received message can be\n" ..
      "determined using MPI_Get_count on the returned status. The received\n" ..
      "message length must be less than or equal to the buffer length specified\n" ..
      "by count; otherwise, an MPI_ERR_TRUNCATE error occurs.",
    example = "program demo_mpi_recv\n" ..
      "  use mpi_f08\n" ..
      "  implicit none\n" ..
      "  integer :: rank, nprocs, ierr\n" ..
      "  real(8) :: data(100)\n" ..
      "  type(MPI_Status) :: status\n" ..
      "  integer :: recv_count, i\n" ..
      "\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  if (nprocs < 2) then\n" ..
      "    print *, 'This example requires at least 2 processes'\n" ..
      "    call MPI_Abort(MPI_COMM_WORLD, 1, ierr)\n" ..
      "  end if\n" ..
      "\n" ..
      "  if (rank == 0) then\n" ..
      "    ! Send 50 elements to process 1\n" ..
      "    data(1:50) = [(real(i, 8), i = 1, 50)]\n" ..
      "    call MPI_Send(data, 50, MPI_DOUBLE_PRECISION, 1, 99, MPI_COMM_WORLD, ierr)\n" ..
      "    print *, 'Process 0 sent 50 elements'\n" ..
      "  else if (rank == 1) then\n" ..
      "    ! Receive into buffer with room for 100 elements\n" ..
      "    call MPI_Recv(data, 100, MPI_DOUBLE_PRECISION, 0, 99, &\n" ..
      "                  MPI_COMM_WORLD, status, ierr)\n" ..
      "\n" ..
      "    ! Query actual received count\n" ..
      "    call MPI_Get_count(status, MPI_DOUBLE_PRECISION, recv_count, ierr)\n" ..
      "\n" ..
      "    print '(A,I0)', 'Process 1 received elements: ', recv_count\n" ..
      "    print '(A,I0)', 'Source rank: ', status%MPI_SOURCE\n" ..
      "    print '(A,I0)', 'Message tag: ', status%MPI_TAG\n" ..
      "    print '(A,5F6.1)', 'First 5 values: ', data(1:5)\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_recv",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Recv.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Recv",
    params = {
      buf = "Starting address of the receive buffer with room for count elements. The received data is stored starting at this address.",
      comm = "MPI communicator defining the process group.",
      count = "Maximum number of elements to receive. The actual message may be shorter but not longer than this count.",
      datatype = "MPI datatype handle describing each buffer element.",
      ierror = "Error code. Returns MPI_SUCCESS (0) on successful completion.",
      source = "Rank of the sending process within comm, or MPI_ANY_SOURCE to receive from any process. MPI_PROC_NULL is allowed for a null receive.",
      status = "Status object that receives information about the message: status%MPI_SOURCE contains the source rank, status%MPI_TAG contains the tag, and MPI_Get_count can determine the message length.",
      tag = "Message tag for matching, or MPI_ANY_TAG to match any tag.",
    },
    result = "The receive buffer is filled with data from the matching send operation.\n" ..
      "The status object contains metadata about the received message including\n" ..
      "the actual source rank and tag used.",
    see_also = {
      "MPI_Send",
      "MPI_Irecv",
      "MPI_Probe",
      "MPI_Get_count",
      "MPI_Sendrecv",
      "MPI_ANY_SOURCE",
    },
    signature = "MPI_Recv(buf, count, datatype, source, tag, comm, status, ierror)",
    standard = "MPI-1.0",
    summary = "Blocking receive for a message",
  },
  mpi_recv_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Recv_init.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Recv_init",
    see_also = {
      "MPI_Start",
      "MPI_Send_init",
    },
    signature = "MPI_Recv_init(buf, count, datatype, source, tag, comm, request, ierror)",
    standard = "MPI-1.0",
    summary = "Create a persistent receive request, to be fired with MPI_Start",
  },
  mpi_reduce = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Reduce** combines the elements provided in the input buffer of each\n" ..
      "process in the group, using the specified reduction operation **op**, and\n" ..
      "returns the combined value in the output buffer of the process with rank\n" ..
      "**root**. The operation is performed element-wise when count > 1.",
    example = "program demo_mpi_reduce\n" ..
      "  use mpi\n" ..
      "  implicit none\n" ..
      "\n" ..
      "  integer :: ierr, rank, nprocs\n" ..
      "  real(8) :: local_value, global_sum, global_max, global_min\n" ..
      "  real(8), dimension(3) :: local_array, sum_array\n" ..
      "  integer :: i\n" ..
      "\n" ..
      "  ! Initialize MPI\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  ! Each process has a different value based on its rank\n" ..
      "  local_value = real(rank + 1, 8) * 10.0d0\n" ..
      "\n" ..
      "  ! Reduce with SUM operation - result goes to root (rank 0)\n" ..
      "  call MPI_Reduce(local_value, global_sum, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                  MPI_SUM, 0, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  ! Reduce with MAX operation\n" ..
      "  call MPI_Reduce(local_value, global_max, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                  MPI_MAX, 0, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  ! Reduce with MIN operation\n" ..
      "  call MPI_Reduce(local_value, global_min, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                  MPI_MIN, 0, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  ! Only root process has valid results\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A,I0,A)', 'Running with ', nprocs, ' processes'\n" ..
      "    print '(A,F10.2)', 'Global sum: ', global_sum\n" ..
      "    print '(A,F10.2)', 'Global max: ', global_max\n" ..
      "    print '(A,F10.2)', 'Global min: ', global_min\n" ..
      "  end if\n" ..
      "\n" ..
      "  ! Example with arrays: reduce multiple elements at once\n" ..
      "  do i = 1, 3\n" ..
      "    local_array(i) = real(rank * 3 + i, 8)\n" ..
      "  end do\n" ..
      "\n" ..
      "  call MPI_Reduce(local_array, sum_array, 3, MPI_DOUBLE_PRECISION, &\n" ..
      "                  MPI_SUM, 0, MPI_COMM_WORLD, ierr)\n" ..
      "\n" ..
      "  if (rank == 0) then\n" ..
      "    print '(A)', 'Array reduction (SUM):'\n" ..
      "    print '(A,3F8.2)', '  Result: ', sum_array\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_reduce",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce",
    params = {
      comm = "MPI communicator handle defining the process group. Typically MPI_COMM_WORLD for all processes or a user-defined communicator.",
      count = "Number of elements in the send buffer. Must be non-negative and identical across all processes in the communicator.",
      datatype = "MPI datatype handle describing each element. Common values: MPI_INTEGER, MPI_REAL, MPI_DOUBLE_PRECISION, MPI_COMPLEX, MPI_LOGICAL.",
      ierror = "Integer error code. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure.",
      op = "MPI reduction operation handle. Predefined operations: - MPI_MAX - Maximum value - MPI_MIN - Minimum value - MPI_SUM - Sum - MPI_PROD - Product - MPI_LAND - Logical AND - MPI_BAND - Bitwise AND - MPI_LOR - Logical OR - MPI_BOR - Bitwise OR - MPI_LXOR - Logical XOR - MPI_BXOR - Bitwise XOR - MPI_MAXLOC - Maximum value and location - MPI_MINLOC - Minimum value and location",
      recvbuf = "Address of the receive buffer where the reduction result is stored. Only significant at the root process; ignored on other processes.",
      root = "Rank of the root process (0 to size-1) within the communicator. Only this process receives the reduction result in recvbuf.",
      sendbuf = "Address of the send buffer containing count elements of the specified datatype. Each process contributes its local data to the reduction. The root process may use MPI_IN_PLACE to use recvbuf as both input and output.",
    },
    result = "On the root process, **recvbuf** contains the combined result of applying\n" ..
      "the reduction operation to the corresponding elements from all processes.\n" ..
      "The operation is applied element-wise for arrays (when count > 1). The\n" ..
      "recvbuf on non-root processes is not modified and may contain undefined\n" ..
      "values. For MPI_MAXLOC and MPI_MINLOC operations, the result includes\n" ..
      "both the extreme value and the rank of the process that contributed it.",
    see_also = {
      "MPI_Allreduce",
      "MPI_Reduce_scatter",
      "MPI_Op_create",
      "MPI_Comm_rank",
      "MPI_Comm_size",
      "MPI_Init",
      "MPI_Finalize",
    },
    signature = "MPI_Reduce(sendbuf, recvbuf, count, datatype, op, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Perform a global reduction operation across all processes in a communicator",
  },
  mpi_reduce_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_init",
    signature = "MPI_Reduce_init(sendbuf, recvbuf, count, datatype, op, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_reduce_local = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and op as type(MPI_Op); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_local.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "inbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "inout",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_local",
    see_also = {
      "MPI_Reduce",
      "MPI_Op_create",
    },
    signature = "MPI_Reduce_local(inbuf, inout, count, datatype, op, ierror)",
    standard = "MPI-2.2",
    summary = "Apply a reduction operation locally, with no communication",
  },
  mpi_reduce_scatter = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_scatter.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_scatter",
    see_also = {
      "MPI_Reduce",
      "MPI_Scatterv",
    },
    signature = "MPI_Reduce_scatter(sendbuf, recvbuf, recvcounts, datatype, op, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Reduce across ranks and scatter the result",
  },
  mpi_reduce_scatter_block = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_scatter_block.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_scatter_block",
    see_also = {
      "MPI_Reduce_scatter",
      "MPI_Allreduce",
    },
    signature = "MPI_Reduce_scatter_block(sendbuf, recvbuf, recvcount, datatype, op, comm, ierror)",
    standard = "MPI-3.0",
    summary = "Reduce across ranks and scatter equal-sized blocks of the result",
  },
  mpi_reduce_scatter_block_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_scatter_block_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_scatter_block_init",
    signature = "MPI_Reduce_scatter_block_init(sendbuf, recvbuf, recvcount, datatype, op, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_reduce_scatter_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Reduce_scatter_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "recvcounts",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Reduce_scatter_init",
    signature = "MPI_Reduce_scatter_init(sendbuf, recvbuf, recvcounts, datatype, op, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_register_datarep = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Register_datarep.3.php",
    interface = {
      {
        intent = "in",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        name = "read_conversion_fn",
        type = "external",
      },
      {
        name = "write_conversion_fn",
        type = "external",
      },
      {
        name = "dtype_file_extent_fn",
        type = "external",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Register_datarep",
    signature = "MPI_Register_datarep(datarep, read_conversion_fn, write_conversion_fn, dtype_file_extent_fn, extra_state, ierror)",
    standard = "MPI-2.0",
  },
  mpi_replace = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_REPLACE",
    section = "mpif-handles.h",
    type = "integer",
    value = "13",
  },
  mpi_request_free = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Request_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Request_free",
    see_also = {
      "MPI_Wait",
      "MPI_Cancel",
    },
    signature = "MPI_Request_free(request, ierror)",
    standard = "MPI-1.0",
    summary = "Release a request handle without waiting for completion",
  },
  mpi_request_get_status = {
    binding_note = "mpi_f08 spells request as type(MPI_Request) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Request_get_status.3.php",
    interface = {
      {
        intent = "in",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Request_get_status",
    signature = "MPI_Request_get_status(request, flag, status, ierror)",
    standard = "MPI-2.0",
  },
  mpi_request_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_REQUEST_NULL** is the value MPI_Wait and friends leave in a request\n" ..
      "handle once the operation has completed.\n" ..
      "\n" ..
      "It is useful deliberately: waiting on a null request returns at once with an\n" ..
      "empty status, so an array of requests can be pre-filled with it and passed to\n" ..
      "MPI_Waitall even when only some entries were actually posted.",
    example = "  req = MPI_REQUEST_NULL\n" ..
      "  if (has_left)  call MPI_Irecv(l, n, MPI_DOUBLE_PRECISION, left, 1, &\n" ..
      "                                MPI_COMM_WORLD, req(1), ierr)\n" ..
      "  call MPI_Waitall(2, req, stats, ierr)   ! unposted entries are fine",
    kind = "constant",
    module = "mpi",
    name = "MPI_REQUEST_NULL",
    section = "Sentinels",
    see_also = {
      "MPI_Wait",
      "MPI_Waitall",
    },
    standard = "MPI-1.0",
    summary = "The null request handle",
    type = "integer",
    value = "0",
  },
  mpi_rget = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), win as type(MPI_Win) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Rget.3.php",
    interface = {
      {
        dim = "(*)",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Rget",
    signature = "MPI_Rget(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, win, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_rget_accumulate = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), result_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), op as type(MPI_Op), win as type(MPI_Win) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Rget_accumulate.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "result_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "result_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "result_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Rget_accumulate",
    signature = "MPI_Rget_accumulate(origin_addr, origin_count, origin_datatype, result_addr, result_count, result_datatype, target_rank, target_disp, target_count, target_datatype, op, win, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_root = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_ROOT",
    section = "mpif-constants.h",
    type = "integer",
    value = "-4",
  },
  mpi_rput = {
    binding_note = "mpi_f08 spells origin_datatype as type(MPI_Datatype), target_datatype as type(MPI_Datatype), win as type(MPI_Win) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Rput.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "origin_addr",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "origin_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "origin_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_disp",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "target_count",
        type = "integer",
      },
      {
        intent = "in",
        name = "target_datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Rput",
    signature = "MPI_Rput(origin_addr, origin_count, origin_datatype, target_rank, target_disp, target_count, target_datatype, win, request, ierror)",
    standard = "MPI-3.0",
  },
  mpi_rsend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Rsend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "ibuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Rsend",
    see_also = {
      "MPI_Send",
      "MPI_Irsend",
    },
    signature = "MPI_Rsend(ibuf, count, datatype, dest, tag, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Ready send: valid only when the matching receive is already posted",
  },
  mpi_rsend_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Rsend_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Rsend_init",
    signature = "MPI_Rsend_init(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_scan = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Scan** gives rank i the reduction of the contributions of ranks 0\n" ..
      "through i inclusive. With MPI_SUM it is the classic way to turn per-rank\n" ..
      "counts into global offsets -- each rank learns where its own block starts in\n" ..
      "a concatenated array.\n" ..
      "\n" ..
      "Note the inclusive semantics: for an offset you usually want the sum of the\n" ..
      "ranks BEFORE you, which is MPI_Exscan, or MPI_Scan's result minus your own\n" ..
      "contribution.",
    example = "  call MPI_Scan(nlocal, nupto, 1, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, ierr)\n" ..
      "  my_offset = nupto - nlocal        ! exclusive prefix",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scan.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scan",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      count = "Number of elements.",
      datatype = "Datatype of the elements.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      op = "Reduction operation, e.g. MPI_SUM.",
      recvbuf = "Returns the prefix reduction over ranks 0..this rank.",
      sendbuf = "This process's contribution.",
    },
    result = "**recvbuf** holds the reduction over ranks 0 through the caller's rank.",
    see_also = {
      "MPI_Reduce",
      "MPI_Allreduce",
    },
    signature = "MPI_Scan(sendbuf, recvbuf, count, datatype, op, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Inclusive prefix reduction across processes",
  },
  mpi_scan_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), op as type(MPI_Op), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scan_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "op",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scan_init",
    signature = "MPI_Scan_init(sendbuf, recvbuf, count, datatype, op, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_scatter = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Scatter** splits an array on **root** into equal blocks and sends the\n" ..
      "i-th block to rank i. It is the exact inverse of MPI_Gather, and shares its\n" ..
      "trap: **sendcount** is per-destination, not the size of the whole array.\n" ..
      "\n" ..
      "Contrast MPI_Bcast, which gives every process the SAME data; scatter gives\n" ..
      "each a different piece.",
    example = "  real(8) :: whole(10*nprocs), mine(10)\n" ..
      "  call MPI_Scatter(whole, 10, MPI_DOUBLE_PRECISION, &\n" ..
      "                   mine,  10, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scatter.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scatter",
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      recvbuf = "This process's block.",
      recvcount = "Elements received by this process.",
      recvtype = "Datatype of the received elements.",
      root = "Rank holding the data to distribute.",
      sendbuf = "Data to distribute; significant only on **root**.",
      sendcount = "Elements sent to EACH process -- not the total.",
      sendtype = "Datatype of the sent elements.",
    },
    result = "Each process's **recvbuf** holds its own block of **sendbuf**.",
    see_also = {
      "MPI_Gather",
      "MPI_Bcast",
      "MPI_Scatterv",
    },
    signature = "MPI_Scatter(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Distribute distinct blocks from one process to all",
  },
  mpi_scatter_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scatter_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scatter_init",
    signature = "MPI_Scatter_init(sendbuf, sendcount, sendtype, recvbuf, recvcount, recvtype, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_scatterv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scatterv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scatterv",
    see_also = {
      "MPI_Scatter",
      "MPI_Gatherv",
    },
    signature = "MPI_Scatterv(sendbuf, sendcounts, displs, sendtype, recvbuf, recvcount, recvtype, root, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Scatter a varying number of elements from the root to each rank",
  },
  mpi_scatterv_init = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm), info as type(MPI_Info) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Scatterv_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "sendcounts",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "displs",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "root",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Scatterv_init",
    signature = "MPI_Scatterv_init(sendbuf, sendcounts, displs, sendtype, recvbuf, recvcount, recvtype, root, comm, info, request, ierror)",
    standard = "MPI-4.0",
  },
  mpi_seek_cur = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SEEK_CUR",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "602",
  },
  mpi_seek_end = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SEEK_END",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "604",
  },
  mpi_seek_set = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-io-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SEEK_SET",
    section = "mpif-io-constants.h",
    type = "integer",
    value = "600",
  },
  mpi_send = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    description = "**MPI_Send** performs a standard-mode blocking send operation. It transmits\n" ..
      "count elements of the specified datatype from the send buffer to the\n" ..
      "destination process. The call blocks until the send buffer can be safely\n" ..
      "reused by the caller, which may occur before, during, or after the\n" ..
      "matching receive completes, depending on the MPI implementation's\n" ..
      "buffering behavior.",
    example = "program demo_mpi_send\n" ..
      "  use mpi_f08\n" ..
      "  implicit none\n" ..
      "  integer :: rank, nprocs, ierr\n" ..
      "  real(8) :: message(10)\n" ..
      "  type(MPI_Status) :: status\n" ..
      "  integer :: i\n" ..
      "\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  if (nprocs < 2) then\n" ..
      "    print *, 'This example requires at least 2 processes'\n" ..
      "    call MPI_Abort(MPI_COMM_WORLD, 1, ierr)\n" ..
      "  end if\n" ..
      "\n" ..
      "  if (rank == 0) then\n" ..
      "    ! Process 0 sends data to process 1\n" ..
      "    message = [(real(i, 8), i = 1, 10)]\n" ..
      "    print *, 'Process 0 sending:', message(1:5), '...'\n" ..
      "    call MPI_Send(message, 10, MPI_DOUBLE_PRECISION, 1, 42, &\n" ..
      "                  MPI_COMM_WORLD, ierr)\n" ..
      "    print *, 'Process 0 send completed'\n" ..
      "  else if (rank == 1) then\n" ..
      "    ! Process 1 receives data from process 0\n" ..
      "    call MPI_Recv(message, 10, MPI_DOUBLE_PRECISION, 0, 42, &\n" ..
      "                  MPI_COMM_WORLD, status, ierr)\n" ..
      "    print *, 'Process 1 received:', message(1:5), '...'\n" ..
      "  end if\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_send",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Send.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Send",
    params = {
      buf = "Starting address of the send buffer containing count elements of the specified datatype. The buffer contents are transmitted to the destination.",
      comm = "MPI communicator defining the process group.",
      count = "Number of elements to send. Must be non-negative. A count of 0 sends an empty message.",
      datatype = "MPI datatype handle describing each buffer element. Common types: MPI_INTEGER, MPI_REAL, MPI_DOUBLE_PRECISION, MPI_COMPLEX, MPI_LOGICAL.",
      dest = "Rank of destination process within comm (0 to comm_size-1). MPI_PROC_NULL is allowed for a null send (no operation).",
      ierror = "Error code. Returns MPI_SUCCESS (0) on successful completion.",
      tag = "Message tag for matching with a corresponding receive. Must be non-negative and less than MPI_TAG_UB.",
    },
    result = "The send buffer data is transmitted to the destination process. The call\n" ..
      "returns when the buffer can be safely reused; this does not guarantee\n" ..
      "the message has been received. Use MPI_Ssend for synchronous behavior\n" ..
      "or MPI_Bsend for buffered sends.",
    see_also = {
      "MPI_Recv",
      "MPI_Isend",
      "MPI_Ssend",
      "MPI_Bsend",
      "MPI_Sendrecv",
      "MPI_Probe",
    },
    signature = "MPI_Send(buf, count, datatype, dest, tag, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Standard-mode blocking send",
  },
  mpi_send_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Send_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Send_init",
    see_also = {
      "MPI_Start",
      "MPI_Recv_init",
    },
    signature = "MPI_Send_init(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
    summary = "Create a persistent send request, to be fired with MPI_Start",
  },
  mpi_sendrecv = {
    binding_note = "mpi_f08 spells sendtype as type(MPI_Datatype), recvtype as type(MPI_Datatype), comm as type(MPI_Comm) and status as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Sendrecv** executes a blocking send and receive operation in a single\n" ..
      "call. It sends data from sendbuf to the destination process and receives\n" ..
      "data into recvbuf from the source process. This routine is useful for\n" ..
      "avoiding deadlocks that can occur with separate send and receive calls,\n" ..
      "particularly in ring or shift communication patterns.",
    example = "program demo_mpi_sendrecv\n" ..
      "  use mpi_f08\n" ..
      "  implicit none\n" ..
      "  integer :: rank, nprocs, ierr\n" ..
      "  integer :: left, right\n" ..
      "  real(8) :: sendbuf, recvbuf\n" ..
      "  type(MPI_Status) :: status\n" ..
      "\n" ..
      "  call MPI_Init(ierr)\n" ..
      "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)\n" ..
      "  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)\n" ..
      "\n" ..
      "  ! Set up ring topology\n" ..
      "  left = mod(rank - 1 + nprocs, nprocs)\n" ..
      "  right = mod(rank + 1, nprocs)\n" ..
      "\n" ..
      "  ! Each process sends its rank to the right neighbor\n" ..
      "  ! and receives from the left neighbor\n" ..
      "  sendbuf = real(rank, 8)\n" ..
      "\n" ..
      "  call MPI_Sendrecv(sendbuf, 1, MPI_DOUBLE_PRECISION, right, 100, &\n" ..
      "                    recvbuf, 1, MPI_DOUBLE_PRECISION, left, 100, &\n" ..
      "                    MPI_COMM_WORLD, status, ierr)\n" ..
      "\n" ..
      "  print '(A,I0,A,F4.1,A,I0)', 'Rank ', rank, ' received ', recvbuf, &\n" ..
      "        ' from rank ', status%MPI_SOURCE\n" ..
      "\n" ..
      "  call MPI_Finalize(ierr)\n" ..
      "\n" ..
      "end program demo_mpi_sendrecv",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Sendrecv.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "sendbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "sendcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtag",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "recvbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "recvcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Sendrecv",
    params = {
      comm = "MPI communicator for the operation.",
      dest = "Rank of destination process within comm. Can be MPI_PROC_NULL for no send.",
      ierror = "Error code. Returns MPI_SUCCESS (0) on success.",
      recvbuf = "Starting address of the receive buffer with room for recvcount elements.",
      recvcount = "Maximum number of elements to receive.",
      recvtag = "Message tag for matching, or MPI_ANY_TAG to match any tag.",
      recvtype = "MPI datatype of each receive buffer element.",
      sendbuf = "Starting address of the send buffer containing sendcount elements of type sendtype to be sent to the destination process.",
      sendcount = "Number of elements to send. Must be non-negative.",
      sendtag = "Message tag for the send operation. Must be non-negative.",
      sendtype = "MPI datatype of each send buffer element.",
      source = "Rank of source process, or MPI_ANY_SOURCE to receive from any process.",
      status = "Status object containing source rank, tag, and message size information.",
    },
    result = "The send buffer data is transmitted to the destination process and the\n" ..
      "receive buffer is filled with data from the source process. The status\n" ..
      "object contains information about the received message including the\n" ..
      "actual source rank and tag.",
    see_also = {
      "MPI_Send",
      "MPI_Recv",
      "MPI_Sendrecv_replace",
      "MPI_Isend",
      "MPI_Irecv",
    },
    signature = "MPI_Sendrecv(sendbuf, sendcount, sendtype, dest, sendtag, recvbuf, recvcount, recvtype, source, recvtag, comm, status, ierror)",
    standard = "MPI-1.0",
    summary = "Blocking send and receive operation",
  },
  mpi_sendrecv_replace = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Sendrecv_replace.3.php",
    interface = {
      {
        dim = "(*)",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "sendtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "source",
        type = "integer",
      },
      {
        intent = "in",
        name = "recvtag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Sendrecv_replace",
    see_also = {
      "MPI_Sendrecv",
    },
    signature = "MPI_Sendrecv_replace(buf, count, datatype, dest, sendtag, source, recvtag, comm, status, ierror)",
    standard = "MPI-1.0",
    summary = "Send and receive using one buffer for both",
  },
  mpi_session_call_errhandler = {
    binding_note = "mpi_f08 spells session as type(MPI_Session); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Session_call_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "session",
        type = "integer",
      },
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Session_call_errhandler",
    signature = "MPI_Session_call_errhandler(session, errorcode, ierror)",
    standard = "MPI-4.0",
  },
  mpi_session_create_errhandler = {
    binding_note = "mpi_f08 spells errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Session_create_errhandler.3.php",
    interface = {
      {
        name = "function",
        type = "external",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Session_create_errhandler",
    signature = "MPI_Session_create_errhandler(function, errhandler, ierror)",
    standard = "MPI-4.0",
  },
  mpi_session_finalize = {
    binding_note = "mpi_f08 spells session as type(MPI_Session); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Session_finalize.3.php",
    interface = {
      {
        intent = "inout",
        name = "session",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Session_finalize",
    signature = "MPI_Session_finalize(session, ierror)",
    standard = "MPI-4.0",
  },
  mpi_session_get_errhandler = {
    binding_note = "mpi_f08 spells session as type(MPI_Session) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Session_get_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "session",
        type = "integer",
      },
      {
        intent = "out",
        name = "erhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Session_get_errhandler",
    signature = "MPI_Session_get_errhandler(session, erhandler, ierror)",
    standard = "MPI-4.0",
  },
  mpi_session_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SESSION_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_session_set_errhandler = {
    binding_note = "mpi_f08 spells session as type(MPI_Session) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Session_set_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "session",
        type = "integer",
      },
      {
        intent = "out",
        name = "erhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Session_set_errhandler",
    signature = "MPI_Session_set_errhandler(session, erhandler, ierror)",
    standard = "MPI-4.0",
  },
  mpi_short = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SHORT",
    section = "mpif-handles.h",
    type = "integer",
    value = "37",
  },
  mpi_short_int = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SHORT_INT",
    section = "mpif-handles.h",
    type = "integer",
    value = "53",
  },
  mpi_signed_char = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SIGNED_CHAR",
    section = "mpif-handles.h",
    type = "integer",
    value = "36",
  },
  mpi_similar = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SIMILAR",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_sizeof = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Sizeof.3.php",
    interface = {
      {
        name = "x",
        type = "<any type>",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Sizeof",
    see_also = {
      "MPI_Type_size",
      "MPI_Type_match_size",
    },
    signature = "MPI_Sizeof(x, size, ierror)",
    standard = "MPI-2.0",
    summary = "Size in bytes of one element of a Fortran variable",
  },
  mpi_source = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_SOURCE** is the index into a status array at which the sending rank is\n" ..
      "stored. It is how a receive posted with MPI_ANY_SOURCE discovers who actually\n" ..
      "sent the message.\n" ..
      "\n" ..
      "It is an INDEX, not the rank itself: the value wanted is\n" ..
      "`status(MPI_SOURCE)`. Using MPI_SOURCE directly as a rank is a real and\n" ..
      "quiet bug, since it is a small integer and will often name a valid process.",
    example = "  call MPI_Recv(buf, n, MPI_DOUBLE_PRECISION, MPI_ANY_SOURCE, &\n" ..
      "                tag, MPI_COMM_WORLD, status, ierr)\n" ..
      "  isender = status(MPI_SOURCE)          ! not MPI_SOURCE",
    kind = "constant",
    module = "mpi",
    name = "MPI_SOURCE",
    section = "Status",
    see_also = {
      "MPI_STATUS_SIZE",
      "MPI_ANY_SOURCE",
      "MPI_Recv",
    },
    standard = "MPI-1.0",
    summary = "Status array index holding the sender's rank",
    type = "integer",
    value = "1",
  },
  mpi_ssend = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ssend.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ssend",
    see_also = {
      "MPI_Send",
      "MPI_Issend",
    },
    signature = "MPI_Ssend(buf, count, datatype, dest, tag, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Synchronous send: returns only once the matching receive has started",
  },
  mpi_ssend_init = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype), comm as type(MPI_Comm) and request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Ssend_init.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "buf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "dest",
        type = "integer",
      },
      {
        intent = "in",
        name = "tag",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Ssend_init",
    signature = "MPI_Ssend_init(buf, count, datatype, dest, tag, comm, request, ierror)",
    standard = "MPI-1.0",
  },
  mpi_start = {
    binding_note = "mpi_f08 spells request as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Start.3.php",
    interface = {
      {
        intent = "inout",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Start",
    see_also = {
      "MPI_Startall",
      "MPI_Send_init",
    },
    signature = "MPI_Start(request, ierror)",
    standard = "MPI-1.0",
    summary = "Fire one persistent request created by MPI_Send_init or MPI_Recv_init",
  },
  mpi_startall = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Startall.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Startall",
    see_also = {
      "MPI_Start",
      "MPI_Waitall",
    },
    signature = "MPI_Startall(count, array_of_requests, ierror)",
    standard = "MPI-1.0",
    summary = "Fire a whole array of persistent requests",
  },
  mpi_status_f082f = {
    binding_note = "mpi_f08 spells f08_status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Status_f082f.3.php",
    interface = {
      {
        intent = "in",
        name = "f08_status",
        type = "type(MPI_Status)",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "f_status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Status_f082f",
    signature = "MPI_Status_f082f(f08_status, f_status, ierror)",
    standard = "MPI-4.0",
  },
  mpi_status_f2f08 = {
    binding_note = "mpi_f08 spells f08_status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Status_f2f08.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "in",
        name = "f_status",
        type = "integer",
      },
      {
        intent = "out",
        name = "f08_status",
        type = "type(MPI_Status)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Status_f2f08",
    signature = "MPI_Status_f2f08(f_status, f08_status, ierror)",
    standard = "MPI-4.0",
  },
  mpi_status_ignore = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    description = "**MPI_STATUS_IGNORE** tells MPI not to fill in a status, which saves the\n" ..
      "implementation the work of writing it.\n" ..
      "\n" ..
      "It is a COMMON-block variable, not a PARAMETER, so it cannot appear in an\n" ..
      "initialisation expression and it must be in scope -- in the F77 binding that\n" ..
      "means `include 'mpif.h'` in the same program unit. Use MPI_STATUSES_IGNORE for\n" ..
      "the array form taken by MPI_Waitall.",
    example = "  call MPI_Recv(buf, n, MPI_DOUBLE_PRECISION, src, tag, &\n" ..
      "                MPI_COMM_WORLD, MPI_STATUS_IGNORE, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_STATUS_IGNORE",
    section = "Status",
    see_also = {
      "MPI_Recv",
      "MPI_Wait",
      "MPI_STATUS_SIZE",
    },
    standard = "MPI-2.0",
    summary = "Pass instead of a status array when the status is not wanted",
    type = "integer",
  },
  mpi_status_set_cancelled = {
    binding_note = "mpi_f08 spells status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Status_set_cancelled.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "inout",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Status_set_cancelled",
    signature = "MPI_Status_set_cancelled(status, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_status_set_elements = {
    binding_note = "mpi_f08 spells status as type(MPI_Status) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Status_set_elements.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "inout",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Status_set_elements",
    signature = "MPI_Status_set_elements(status, datatype, count, ierror)",
    standard = "MPI-2.0",
  },
  mpi_status_set_elements_x = {
    binding_note = "mpi_f08 spells status as type(MPI_Status) and datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Status_set_elements_x.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "inout",
        name = "status",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "count",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Status_set_elements_x",
    signature = "MPI_Status_set_elements_x(status, datatype, count, ierror)",
    standard = "MPI-3.0",
  },
  mpi_status_size = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    description = "**MPI_STATUS_SIZE** is the extent of the INTEGER array that holds an MPI\n" ..
      "status in the Fortran binding. Every status variable is declared with it:\n" ..
      "\n" ..
      "```fortran\n" ..
      "integer :: status(MPI_STATUS_SIZE)\n" ..
      "```\n" ..
      "\n" ..
      "and an array of statuses, for MPI_Waitall, is\n" ..
      "`INTEGER stats(MPI_STATUS_SIZE, n)` -- that order, which is easy to reverse.\n" ..
      "\n" ..
      "The array's fields are reached by the named indices MPI_SOURCE, MPI_TAG and\n" ..
      "MPI_ERROR; the remaining entries are opaque, and the received length is\n" ..
      "obtained through MPI_Get_count rather than by indexing.",
    example = "  integer :: status(MPI_STATUS_SIZE)\n" ..
      "  call MPI_Recv(buf, n, MPI_DOUBLE_PRECISION, MPI_ANY_SOURCE, &\n" ..
      "                tag, MPI_COMM_WORLD, status, ierr)\n" ..
      "  src = status(MPI_SOURCE)",
    kind = "constant",
    module = "mpi",
    name = "MPI_STATUS_SIZE",
    section = "Status",
    see_also = {
      "MPI_SOURCE",
      "MPI_Get_count",
      "MPI_Recv",
    },
    standard = "MPI-1.0",
    summary = "Length of the Fortran status array",
    type = "integer",
    value = "6",
  },
  mpi_statuses_ignore = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_STATUSES_IGNORE",
    section = "mpif-sentinels.h",
    type = "integer",
  },
  mpi_subarrays_supported = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-config.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SUBARRAYS_SUPPORTED",
    section = "mpif-config.h",
    type = "logical",
    value = ".false.",
  },
  mpi_subversion = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SUBVERSION",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_success = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_SUCCESS** is the value (zero) returned in **ierror** when a call\n" ..
      "succeeds.\n" ..
      "\n" ..
      "Testing it is nearly always pointless: MPI's default error handler on\n" ..
      "MPI_COMM_WORLD aborts the job rather than returning, so a failing call does\n" ..
      "not come back at all. The check becomes meaningful only after\n" ..
      "MPI_Comm_set_errhandler installs MPI_ERRORS_RETURN.",
    example = "  call MPI_Comm_set_errhandler(MPI_COMM_WORLD, MPI_ERRORS_RETURN, ierr)\n" ..
      "  call MPI_Send(buf, n, MPI_INTEGER, dest, tag, MPI_COMM_WORLD, ierr)\n" ..
      "  if (ierr /= MPI_SUCCESS) call handle_failure(ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SUCCESS",
    section = "Error codes",
    see_also = {
      "MPI_Abort",
    },
    standard = "MPI-1.0",
    summary = "Error code indicating success",
    type = "integer",
    value = "0",
  },
  mpi_sum = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    description = "**MPI_SUM** is the predefined reduction operation adding contributions\n" ..
      "elementwise, for MPI_Reduce, MPI_Allreduce and MPI_Scan.\n" ..
      "\n" ..
      "Floating-point addition is not associative, so the result depends on the\n" ..
      "order the implementation chose -- which may differ between runs, and between\n" ..
      "process counts, even on identical input. A reduction that must be\n" ..
      "bit-reproducible needs a fixed-order reduction written by hand.",
    example = "  call MPI_Allreduce(elocal, etotal, 1, MPI_DOUBLE_PRECISION, &\n" ..
      "                     MPI_SUM, MPI_COMM_WORLD, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_SUM",
    section = "Reduction operations",
    see_also = {
      "MPI_Reduce",
      "MPI_Allreduce",
      "MPI_MAX",
    },
    standard = "MPI-1.0",
    summary = "Reduction operation: sum",
    type = "integer",
    value = "3",
  },
  mpi_t_err_cannot_init = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_CANNOT_INIT",
    section = "mpif-constants.h",
    type = "integer",
    value = "56",
  },
  mpi_t_err_cvar_set_never = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_CVAR_SET_NEVER",
    section = "mpif-constants.h",
    type = "integer",
    value = "64",
  },
  mpi_t_err_cvar_set_not_now = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_CVAR_SET_NOT_NOW",
    section = "mpif-constants.h",
    type = "integer",
    value = "63",
  },
  mpi_t_err_invalid = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_INVALID",
    section = "mpif-constants.h",
    type = "integer",
    value = "72",
  },
  mpi_t_err_invalid_handle = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_INVALID_HANDLE",
    section = "mpif-constants.h",
    type = "integer",
    value = "59",
  },
  mpi_t_err_invalid_index = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_INVALID_INDEX",
    section = "mpif-constants.h",
    type = "integer",
    value = "57",
  },
  mpi_t_err_invalid_item = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_INVALID_ITEM",
    section = "mpif-constants.h",
    type = "integer",
    value = "58",
  },
  mpi_t_err_invalid_session = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_INVALID_SESSION",
    section = "mpif-constants.h",
    type = "integer",
    value = "62",
  },
  mpi_t_err_memory = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_MEMORY",
    section = "mpif-constants.h",
    type = "integer",
    value = "54",
  },
  mpi_t_err_not_initialized = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_NOT_INITIALIZED",
    section = "mpif-constants.h",
    type = "integer",
    value = "55",
  },
  mpi_t_err_out_of_handles = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_OUT_OF_HANDLES",
    section = "mpif-constants.h",
    type = "integer",
    value = "60",
  },
  mpi_t_err_out_of_sessions = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_OUT_OF_SESSIONS",
    section = "mpif-constants.h",
    type = "integer",
    value = "61",
  },
  mpi_t_err_pvar_no_atomic = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_PVAR_NO_ATOMIC",
    section = "mpif-constants.h",
    type = "integer",
    value = "67",
  },
  mpi_t_err_pvar_no_startstop = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_PVAR_NO_STARTSTOP",
    section = "mpif-constants.h",
    type = "integer",
    value = "65",
  },
  mpi_t_err_pvar_no_write = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_T_ERR_PVAR_NO_WRITE",
    section = "mpif-constants.h",
    type = "integer",
    value = "66",
  },
  mpi_tag = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_TAG** indexes a status array at the position holding the tag of the\n" ..
      "received message -- the counterpart of MPI_SOURCE, and the way a receive\n" ..
      "posted with MPI_ANY_TAG learns what actually arrived. It is an index, not the\n" ..
      "tag itself.",
    example = "  call MPI_Recv(buf, n, MPI_INTEGER, MPI_ANY_SOURCE, MPI_ANY_TAG, &\n" ..
      "                MPI_COMM_WORLD, status, ierr)\n" ..
      "  itag = status(MPI_TAG)",
    kind = "constant",
    module = "mpi",
    name = "MPI_TAG",
    section = "Status",
    see_also = {
      "MPI_SOURCE",
      "MPI_ANY_TAG",
    },
    standard = "MPI-1.0",
    summary = "Status array index holding the message tag",
    type = "integer",
    value = "2",
  },
  mpi_tag_ub = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_TAG_UB",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_test = {
    binding_note = "mpi_f08 spells request as type(MPI_Request) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Test.3.php",
    interface = {
      {
        intent = "inout",
        name = "request",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Test",
    see_also = {
      "MPI_Wait",
      "MPI_Testall",
      "MPI_Request_free",
    },
    signature = "MPI_Test(request, flag, status, ierror)",
    standard = "MPI-1.0",
    summary = "Test whether a nonblocking operation has completed, without blocking",
  },
  mpi_test_cancelled = {
    binding_note = "mpi_f08 spells status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Test_cancelled.3.php",
    interface = {
      {
        dim = "(6)",
        intent = "in",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Test_cancelled",
    signature = "MPI_Test_cancelled(status, flag, ierror)",
    standard = "MPI-1.0",
  },
  mpi_testall = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and array_of_statuses as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Testall.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        dim = "(6, *)",
        intent = "out",
        name = "array_of_statuses",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Testall",
    see_also = {
      "MPI_Waitall",
      "MPI_Test",
    },
    signature = "MPI_Testall(count, array_of_requests, flag, array_of_statuses, ierror)",
    standard = "MPI-1.0",
    summary = "Test whether every request in an array has completed",
  },
  mpi_testany = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Testany.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "index",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Testany",
    see_also = {
      "MPI_Waitany",
      "MPI_Test",
    },
    signature = "MPI_Testany(count, array_of_requests, index, flag, status, ierror)",
    standard = "MPI-1.0",
    summary = "Test whether any one request in an array has completed",
  },
  mpi_testsome = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and array_of_statuses as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Testsome.3.php",
    interface = {
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "outcount",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_indices",
        type = "integer",
      },
      {
        dim = "(6, *)",
        intent = "out",
        name = "array_of_statuses",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Testsome",
    see_also = {
      "MPI_Waitsome",
      "MPI_Testany",
    },
    signature = "MPI_Testsome(incount, array_of_requests, outcount, array_of_indices, array_of_statuses, ierror)",
    standard = "MPI-1.0",
    summary = "Test which of an array of requests have completed",
  },
  mpi_thread_funneled = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_THREAD_FUNNELED",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_thread_multiple = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_THREAD_MULTIPLE",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_thread_serialized = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_THREAD_SERIALIZED",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_thread_single = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_THREAD_SINGLE",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_topo_test = {
    binding_note = "mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Topo_test.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Topo_test",
    signature = "MPI_Topo_test(comm, status, ierror)",
    standard = "MPI-1.0",
  },
  mpi_type_commit = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    description = "**MPI_Type_commit** finalizes a derived datatype so it can be used in\n" ..
      "communication calls. Using an uncommitted type is an error, and it is the\n" ..
      "usual reason a freshly constructed datatype fails.\n" ..
      "\n" ..
      "Only derived types need it -- MPI_INTEGER and friends are already usable.",
    example = "  call MPI_Type_contiguous(3, MPI_DOUBLE_PRECISION, xyz_type, ierr)\n" ..
      "  call MPI_Type_commit(xyz_type, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_commit.3.php",
    interface = {
      {
        intent = "inout",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_commit",
    params = {
      datatype = "The derived type to commit, from MPI_Type_contiguous or similar.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "**datatype** becomes usable in communication calls.",
    see_also = {
      "MPI_Type_contiguous",
      "MPI_Type_free",
    },
    signature = "MPI_Type_commit(datatype, ierror)",
    standard = "MPI-1.0",
    summary = "Make a derived datatype usable",
  },
  mpi_type_contiguous = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    description = "**MPI_Type_contiguous** builds a datatype describing **count** consecutive\n" ..
      "**oldtype** elements -- the simplest derived type, useful for sending\n" ..
      "fixed-size records as one unit rather than counting elements everywhere.\n" ..
      "\n" ..
      "The handle is not usable until MPI_Type_commit has been called on it, and\n" ..
      "leaks unless MPI_Type_free is called eventually.",
    example = "  call MPI_Type_contiguous(3, MPI_DOUBLE_PRECISION, xyz_type, ierr)\n" ..
      "  call MPI_Type_commit(xyz_type, ierr)\n" ..
      "  call MPI_Send(pos, natoms, xyz_type, dest, 1, MPI_COMM_WORLD, ierr)\n" ..
      "  call MPI_Type_free(xyz_type, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_contiguous.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_contiguous",
    params = {
      count = "Number of **oldtype** elements in the new type.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      newtype = "Returns the new datatype handle, uncommitted.",
      oldtype = "The datatype being replicated.",
    },
    result = "**newtype** is a handle that must be committed before use.",
    see_also = {
      "MPI_Type_commit",
      "MPI_Type_free",
    },
    signature = "MPI_Type_contiguous(count, oldtype, newtype, ierror)",
    standard = "MPI-1.0",
    summary = "Define a datatype of contiguous elements",
  },
  mpi_type_create_darray = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_darray.3.php",
    interface = {
      {
        intent = "in",
        name = "size",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "ndims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "gsize_array",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "distrib_array",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "darg_array",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "psize_array",
        type = "integer",
      },
      {
        intent = "in",
        name = "order",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_darray",
    signature = "MPI_Type_create_darray(size, rank, ndims, gsize_array, distrib_array, darg_array, psize_array, order, oldtype, newtype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_f90_complex = {
    binding_note = "mpi_f08 spells newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_f90_complex.3.php",
    interface = {
      {
        intent = "in",
        name = "p",
        type = "integer",
      },
      {
        intent = "in",
        name = "r",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_f90_complex",
    signature = "MPI_Type_create_f90_complex(p, r, newtype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_f90_integer = {
    binding_note = "mpi_f08 spells newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_f90_integer.3.php",
    interface = {
      {
        intent = "in",
        name = "r",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_f90_integer",
    signature = "MPI_Type_create_f90_integer(r, newtype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_f90_real = {
    binding_note = "mpi_f08 spells newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_f90_real.3.php",
    interface = {
      {
        intent = "in",
        name = "p",
        type = "integer",
      },
      {
        intent = "in",
        name = "r",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_f90_real",
    signature = "MPI_Type_create_f90_real(p, r, newtype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_hindexed = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_hindexed.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_blocklengths",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_displacements",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_hindexed",
    see_also = {
      "MPI_Type_indexed",
      "MPI_Get_address",
    },
    signature = "MPI_Type_create_hindexed(count, array_of_blocklengths, array_of_displacements, oldtype, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Like MPI_Type_indexed, with displacements given in bytes",
  },
  mpi_type_create_hindexed_block = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_hindexed_block.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "blocklength",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_displacements",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_hindexed_block",
    signature = "MPI_Type_create_hindexed_block(count, blocklength, array_of_displacements, oldtype, newtype, ierror)",
    standard = "MPI-3.0",
  },
  mpi_type_create_hvector = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_hvector.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "blocklength",
        type = "integer",
      },
      {
        intent = "in",
        name = "stride",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_hvector",
    see_also = {
      "MPI_Type_vector",
      "MPI_Get_address",
    },
    signature = "MPI_Type_create_hvector(count, blocklength, stride, oldtype, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Like MPI_Type_vector, with the stride given in bytes",
  },
  mpi_type_create_indexed_block = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_indexed_block.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "blocklength",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_displacements",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_indexed_block",
    signature = "MPI_Type_create_indexed_block(count, blocklength, array_of_displacements, oldtype, newtype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_keyval.3.php",
    interface = {
      {
        name = "type_copy_attr_fn",
        type = "external",
      },
      {
        name = "type_delete_attr_fn",
        type = "external",
      },
      {
        intent = "out",
        name = "type_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_keyval",
    signature = "MPI_Type_create_keyval(type_copy_attr_fn, type_delete_attr_fn, type_keyval, extra_state, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_create_resized = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_resized.3.php",
    interface = {
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "in",
        name = "lb",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_resized",
    see_also = {
      "MPI_Type_get_extent",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_create_resized(oldtype, lb, extent, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Change the lower bound and extent of a datatype",
  },
  mpi_type_create_struct = {
    binding_note = "mpi_f08 spells array_of_types as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_struct.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_block_lengths",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_displacements",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_types",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_struct",
    see_also = {
      "MPI_Get_address",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_create_struct(count, array_of_block_lengths, array_of_displacements, array_of_types, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Build a datatype from blocks of differing types and displacements",
  },
  mpi_type_create_subarray = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_create_subarray.3.php",
    interface = {
      {
        intent = "in",
        name = "ndims",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "size_array",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "subsize_array",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "start_array",
        type = "integer",
      },
      {
        intent = "in",
        name = "order",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_create_subarray",
    see_also = {
      "MPI_Type_create_darray",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_create_subarray(ndims, size_array, subsize_array, start_array, order, oldtype, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Build a datatype describing a sub-block of a multidimensional array",
  },
  mpi_type_delete_attr = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_delete_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "type_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_delete_attr",
    signature = "MPI_Type_delete_attr(datatype, type_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_dup = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_dup.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_dup",
    see_also = {
      "MPI_Type_commit",
    },
    signature = "MPI_Type_dup(datatype, newtype, ierror)",
    standard = "MPI-2.0",
    summary = "Duplicate a datatype, attributes included",
  },
  mpi_type_dup_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_TYPE_DUP_FN.3.php",
    interface = {
      {
        name = "datatype",
        type = "integer",
      },
      {
        name = "type_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_TYPE_DUP_FN",
    signature = "MPI_TYPE_DUP_FN(datatype, type_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_type_free = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    description = "**MPI_Type_free** releases a derived datatype and sets the handle to\n" ..
      "MPI_DATATYPE_NULL. Types derived FROM it stay valid, as does any\n" ..
      "communication already in progress.\n" ..
      "\n" ..
      "Freeing types matters in code that builds them inside a loop; a long run can\n" ..
      "otherwise exhaust the implementation's handle table.",
    example = "  call MPI_Type_free(xyz_type, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_free",
    params = {
      datatype = "The derived type to free. Set to MPI_DATATYPE_NULL on return.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "The handle is released and set to MPI_DATATYPE_NULL.",
    see_also = {
      "MPI_Type_contiguous",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_free(datatype, ierror)",
    standard = "MPI-1.0",
    summary = "Release a derived datatype",
  },
  mpi_type_free_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_free_keyval.3.php",
    interface = {
      {
        intent = "inout",
        name = "type_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_free_keyval",
    signature = "MPI_Type_free_keyval(type_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_attr = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "type_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "attribute_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_attr",
    signature = "MPI_Type_get_attr(datatype, type_keyval, attribute_val, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_contents = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and array_of_datatypes as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_contents.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "max_integers",
        type = "integer",
      },
      {
        intent = "in",
        name = "max_addresses",
        type = "integer",
      },
      {
        intent = "in",
        name = "max_datatypes",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_integers",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_addresses",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_datatypes",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_contents",
    signature = "MPI_Type_get_contents(datatype, max_integers, max_addresses, max_datatypes, array_of_integers, array_of_addresses, array_of_datatypes, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_envelope = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_envelope.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "num_integers",
        type = "integer",
      },
      {
        intent = "out",
        name = "num_addresses",
        type = "integer",
      },
      {
        intent = "out",
        name = "num_datatypes",
        type = "integer",
      },
      {
        intent = "out",
        name = "combiner",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_envelope",
    signature = "MPI_Type_get_envelope(datatype, num_integers, num_addresses, num_datatypes, combiner, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_extent = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_extent.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "lb",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_extent",
    see_also = {
      "MPI_Type_size",
      "MPI_Type_create_resized",
    },
    signature = "MPI_Type_get_extent(datatype, lb, extent, ierror)",
    standard = "MPI-2.0",
    summary = "Lower bound and extent of a datatype, in bytes",
  },
  mpi_type_get_extent_x = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_extent_x.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "lb",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_extent_x",
    signature = "MPI_Type_get_extent_x(datatype, lb, extent, ierror)",
    standard = "MPI-3.0",
  },
  mpi_type_get_name = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_name.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "type_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_name",
    signature = "MPI_Type_get_name(datatype, type_name, resultlen, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_true_extent = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_true_extent.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "true_lb",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "true_extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_true_extent",
    signature = "MPI_Type_get_true_extent(datatype, true_lb, true_extent, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_get_true_extent_x = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_get_true_extent_x.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "true_lb",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "true_extent",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_get_true_extent_x",
    signature = "MPI_Type_get_true_extent_x(datatype, true_lb, true_extent, ierror)",
    standard = "MPI-3.0",
  },
  mpi_type_indexed = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_indexed.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_blocklengths",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "array_of_displacements",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_indexed",
    see_also = {
      "MPI_Type_create_hindexed",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_indexed(count, array_of_blocklengths, array_of_displacements, oldtype, newtype, ierror)",
    standard = "MPI-1.0",
    summary = "Build a datatype from blocks at arbitrary element displacements",
  },
  mpi_type_match_size = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_match_size.3.php",
    interface = {
      {
        intent = "in",
        name = "typeclass",
        type = "integer",
      },
      {
        intent = "in",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_match_size",
    signature = "MPI_Type_match_size(typeclass, size, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_null_copy_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_TYPE_NULL_COPY_FN.3.php",
    interface = {
      {
        name = "datatype",
        type = "integer",
      },
      {
        name = "type_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_TYPE_NULL_COPY_FN",
    signature = "MPI_TYPE_NULL_COPY_FN(datatype, type_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_type_null_delete_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_TYPE_NULL_DELETE_FN.3.php",
    interface = {
      {
        name = "datatype",
        type = "integer",
      },
      {
        name = "type_keyval",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_TYPE_NULL_DELETE_FN",
    signature = "MPI_TYPE_NULL_DELETE_FN(datatype, type_keyval, attribute_val_out, extra_state, ierr)",
    standard = "MPI-2.0",
  },
  mpi_type_set_attr = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_set_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "type_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "attr_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_set_attr",
    signature = "MPI_Type_set_attr(datatype, type_keyval, attr_val, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_set_name = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_set_name.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "type_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_set_name",
    signature = "MPI_Type_set_name(datatype, type_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_type_size = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_size.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_size",
    see_also = {
      "MPI_Type_get_extent",
      "MPI_Get_count",
    },
    signature = "MPI_Type_size(datatype, size, ierror)",
    standard = "MPI-1.0",
    summary = "Number of bytes the data of one element of a datatype occupies",
  },
  mpi_type_size_x = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_size_x.3.php",
    interface = {
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_size_x",
    signature = "MPI_Type_size_x(datatype, size, ierror)",
    standard = "MPI-3.0",
  },
  mpi_type_vector = {
    binding_note = "mpi_f08 spells oldtype as type(MPI_Datatype) and newtype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Type_vector.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        intent = "in",
        name = "blocklength",
        type = "integer",
      },
      {
        intent = "in",
        name = "stride",
        type = "integer",
      },
      {
        intent = "in",
        name = "oldtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "newtype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Type_vector",
    see_also = {
      "MPI_Type_contiguous",
      "MPI_Type_commit",
    },
    signature = "MPI_Type_vector(count, blocklength, stride, oldtype, newtype, ierror)",
    standard = "MPI-1.0",
    summary = "Build a datatype from equally spaced blocks of an existing type",
  },
  mpi_typeclass_complex = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_TYPECLASS_COMPLEX",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_typeclass_integer = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_TYPECLASS_INTEGER",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_typeclass_real = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_TYPECLASS_REAL",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_ub = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UB",
    section = "mpif-handles.h",
    type = "integer",
    value = "3",
  },
  mpi_uint16_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UINT16_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "61",
  },
  mpi_uint32_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UINT32_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "63",
  },
  mpi_uint64_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UINT64_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "65",
  },
  mpi_uint8_t = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UINT8_T",
    section = "mpif-handles.h",
    type = "integer",
    value = "59",
  },
  mpi_undefined = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    description = "**MPI_UNDEFINED** marks a value that does not exist. Two places matter: as\n" ..
      "the colour argument to MPI_Comm_split it excludes the process, which then\n" ..
      "receives MPI_COMM_NULL; and MPI_Get_count returns it when the message length\n" ..
      "is not a whole multiple of the datatype's extent.\n" ..
      "\n" ..
      "The second is worth checking for -- an unchecked MPI_UNDEFINED count is a\n" ..
      "large negative number and will be used as a loop bound.",
    example = "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, n, ierr)\n" ..
      "  if (n == MPI_UNDEFINED) call MPI_Abort(MPI_COMM_WORLD, 2, ierr)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNDEFINED",
    section = "Sentinels",
    see_also = {
      "MPI_Get_count",
      "MPI_Comm_split",
    },
    standard = "MPI-1.0",
    summary = "Sentinel for an undefined value",
    type = "integer",
    value = "-32766",
  },
  mpi_unequal = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNEQUAL",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_universe_size = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNIVERSE_SIZE",
    section = "mpif-constants.h",
    type = "integer",
    value = "6",
  },
  mpi_unpack = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype) and comm as type(MPI_Comm); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Unpack.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "inbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "insize",
        type = "integer",
      },
      {
        intent = "inout",
        name = "position",
        type = "integer",
      },
      {
        dim = "(*)",
        name = "outbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "outcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Unpack",
    see_also = {
      "MPI_Pack",
    },
    signature = "MPI_Unpack(inbuf, insize, position, outbuf, outcount, datatype, comm, ierror)",
    standard = "MPI-1.0",
    summary = "Unpack data from an MPI_PACKED buffer",
  },
  mpi_unpack_external = {
    binding_note = "mpi_f08 spells datatype as type(MPI_Datatype); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Unpack_external.3.php",
    interface = {
      {
        intent = "in",
        name = "datarep",
        type = "character(len=*)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "inbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "insize",
        type = "integer(8)",
      },
      {
        intent = "inout",
        name = "position",
        type = "integer(8)",
      },
      {
        dim = "(*)",
        name = "outbuf",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "outcount",
        type = "integer",
      },
      {
        intent = "in",
        name = "datatype",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Unpack_external",
    signature = "MPI_Unpack_external(datarep, inbuf, insize, position, outbuf, outcount, datatype, ierror)",
    standard = "MPI-2.0",
  },
  mpi_unpublish_name = {
    binding_note = "mpi_f08 spells info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Unpublish_name.3.php",
    interface = {
      {
        intent = "in",
        name = "service_name",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "port_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Unpublish_name",
    signature = "MPI_Unpublish_name(service_name, info, port_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_unsigned = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNSIGNED",
    section = "mpif-handles.h",
    type = "integer",
    value = "40",
  },
  mpi_unsigned_char = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNSIGNED_CHAR",
    section = "mpif-handles.h",
    type = "integer",
    value = "35",
  },
  mpi_unsigned_long = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNSIGNED_LONG",
    section = "mpif-handles.h",
    type = "integer",
    value = "42",
  },
  mpi_unsigned_long_long = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNSIGNED_LONG_LONG",
    section = "mpif-handles.h",
    type = "integer",
    value = "44",
  },
  mpi_unsigned_short = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNSIGNED_SHORT",
    section = "mpif-handles.h",
    type = "integer",
    value = "38",
  },
  mpi_unweighted = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_UNWEIGHTED",
    section = "mpif-sentinels.h",
    type = "integer",
  },
  mpi_version = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_VERSION",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_wait = {
    binding_note = "mpi_f08 spells request as type(MPI_Request) and status as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Wait** blocks until the operation identified by **request** finishes,\n" ..
      "then frees the request and sets it to MPI_REQUEST_NULL.\n" ..
      "\n" ..
      "For a receive, **status** is where the actual source, tag and length finally\n" ..
      "become available -- MPI_Irecv had nowhere to put them. For a send it carries\n" ..
      "little of interest.\n" ..
      "\n" ..
      "Waiting on an already-null request returns immediately with an empty status,\n" ..
      "which is what makes it safe to wait over an array of requests where only some\n" ..
      "were posted.",
    example = "  call MPI_Wait(req, status, ierr)\n" ..
      "  src = status(MPI_SOURCE)\n" ..
      "  call MPI_Get_count(status, MPI_DOUBLE_PRECISION, nrecv, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Wait.3.php",
    interface = {
      {
        intent = "inout",
        name = "request",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Wait",
    params = {
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
      request = "The handle from MPI_Isend/MPI_Irecv. Set to MPI_REQUEST_NULL on return.",
      status = "Status of the completed operation. For a receive this is where MPI_SOURCE, MPI_TAG and the length come from.",
    },
    result = "Returns once the operation is complete; **request** is freed.",
    see_also = {
      "MPI_Waitall",
      "MPI_Isend",
      "MPI_Irecv",
      "MPI_Get_count",
    },
    signature = "MPI_Wait(request, status, ierror)",
    standard = "MPI-1.0",
    summary = "Block until a non-blocking operation completes",
  },
  mpi_waitall = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and array_of_statuses as type(MPI_Status); ierror is OPTIONAL",
    description = "**MPI_Waitall** completes a whole array of requests. Prefer it to a loop of\n" ..
      "MPI_Wait calls: waiting on request 1 first forces that particular ordering,\n" ..
      "while MPI_Waitall lets the implementation take them as they arrive.\n" ..
      "\n" ..
      "The status array is two-dimensional in Fortran -- INTEGER statuses\n" ..
      "(MPI_STATUS_SIZE, count) -- which is easy to declare the wrong way round.",
    example = "  integer :: req(2), stats(MPI_STATUS_SIZE, 2)\n" ..
      "\n" ..
      "  call MPI_Irecv(rbuf, n, MPI_DOUBLE_PRECISION, left,  9, MPI_COMM_WORLD, req(1), ierr)\n" ..
      "  call MPI_Isend(sbuf, n, MPI_DOUBLE_PRECISION, right, 9, MPI_COMM_WORLD, req(2), ierr)\n" ..
      "  call MPI_Waitall(2, req, stats, ierr)",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Waitall.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        dim = "(6, *)",
        intent = "out",
        name = "array_of_statuses",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Waitall",
    params = {
      array_of_requests = "Requests to complete; all set to MPI_REQUEST_NULL on return.",
      array_of_statuses = "Statuses, declared `INTEGER stats(MPI_STATUS_SIZE, count)`.",
      count = "Number of requests in the array.",
      ierror = "Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.",
    },
    result = "Returns once every request has completed.",
    see_also = {
      "MPI_Wait",
      "MPI_Isend",
      "MPI_Irecv",
    },
    signature = "MPI_Waitall(count, array_of_requests, array_of_statuses, ierror)",
    standard = "MPI-1.0",
    summary = "Block until all of a set of operations complete",
  },
  mpi_waitany = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and status as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Waitany.3.php",
    interface = {
      {
        intent = "in",
        name = "count",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "index",
        type = "integer",
      },
      {
        dim = "(6)",
        intent = "out",
        name = "status",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Waitany",
    see_also = {
      "MPI_Waitall",
      "MPI_Testany",
    },
    signature = "MPI_Waitany(count, array_of_requests, index, status, ierror)",
    standard = "MPI-1.0",
    summary = "Block until any one request in an array completes",
  },
  mpi_waitsome = {
    binding_note = "mpi_f08 spells array_of_requests as type(MPI_Request) and array_of_statuses as type(MPI_Status); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Waitsome.3.php",
    interface = {
      {
        intent = "in",
        name = "incount",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "inout",
        name = "array_of_requests",
        type = "integer",
      },
      {
        intent = "out",
        name = "outcount",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "array_of_indices",
        type = "integer",
      },
      {
        dim = "(6, *)",
        intent = "out",
        name = "array_of_statuses",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Waitsome",
    see_also = {
      "MPI_Waitall",
      "MPI_Testsome",
    },
    signature = "MPI_Waitsome(incount, array_of_requests, outcount, array_of_indices, array_of_statuses, ierror)",
    standard = "MPI-1.0",
    summary = "Block until at least one of an array of requests completes",
  },
  mpi_wchar = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WCHAR",
    section = "mpif-handles.h",
    type = "integer",
    value = "33",
  },
  mpi_weights_empty = {
    binding_note = "declared in mpif-sentinels.h as installed here (Open MPI 5.0.10)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WEIGHTS_EMPTY",
    section = "mpif-sentinels.h",
    type = "integer",
  },
  mpi_win_allocate = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm), baseptr as type(C_ptr) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_allocate.3.php",
    interface = {
      {
        name = "size",
        type = "integer(8)",
      },
      {
        name = "disp_unit",
        type = "integer",
      },
      {
        name = "info",
        type = "integer",
      },
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "baseptr",
        type = "type(C_ptr)",
      },
      {
        name = "win",
        type = "integer",
      },
      {
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_allocate",
    signature = "MPI_Win_allocate(size, disp_unit, info, comm, baseptr, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_allocate_shared = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm), baseptr as type(C_ptr) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_allocate_shared.3.php",
    interface = {
      {
        name = "size",
        type = "integer(8)",
      },
      {
        name = "disp_unit",
        type = "integer",
      },
      {
        name = "info",
        type = "integer",
      },
      {
        name = "comm",
        type = "integer",
      },
      {
        name = "baseptr",
        type = "type(C_ptr)",
      },
      {
        name = "win",
        type = "integer",
      },
      {
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_allocate_shared",
    signature = "MPI_Win_allocate_shared(size, disp_unit, info, comm, baseptr, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_attach = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_attach.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "base",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_attach",
    signature = "MPI_Win_attach(win, base, size, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_base = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_BASE",
    section = "mpif-constants.h",
    type = "integer",
    value = "7",
  },
  mpi_win_call_errhandler = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_call_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "errorcode",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_call_errhandler",
    signature = "MPI_Win_call_errhandler(win, errorcode, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_complete = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_complete.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_complete",
    signature = "MPI_Win_complete(win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_create = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_create.3.php",
    interface = {
      {
        dim = "(*)",
        intent = "in",
        name = "base",
        type = "<any type>",
      },
      {
        intent = "in",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "in",
        name = "disp_unit",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_create",
    see_also = {
      "MPI_Win_fence",
      "MPI_Put",
      "MPI_Get",
    },
    signature = "MPI_Win_create(base, size, disp_unit, info, comm, win, ierror)",
    standard = "MPI-2.0",
    summary = "Expose a local memory region as a one-sided access window",
  },
  mpi_win_create_dynamic = {
    binding_note = "mpi_f08 spells info as type(MPI_Info), comm as type(MPI_Comm) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_create_dynamic.3.php",
    interface = {
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "out",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_create_dynamic",
    signature = "MPI_Win_create_dynamic(info, comm, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_create_errhandler = {
    binding_note = "mpi_f08 spells errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_create_errhandler.3.php",
    interface = {
      {
        name = "function",
        type = "external",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_create_errhandler",
    signature = "MPI_Win_create_errhandler(function, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_create_flavor = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_CREATE_FLAVOR",
    section = "mpif-constants.h",
    type = "integer",
    value = "10",
  },
  mpi_win_create_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_create_keyval.3.php",
    interface = {
      {
        name = "win_copy_attr_fn",
        type = "external",
      },
      {
        name = "win_delete_attr_fn",
        type = "external",
      },
      {
        intent = "out",
        name = "win_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "extra_state",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_create_keyval",
    signature = "MPI_Win_create_keyval(win_copy_attr_fn, win_delete_attr_fn, win_keyval, extra_state, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_delete_attr = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_delete_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "win_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_delete_attr",
    signature = "MPI_Win_delete_attr(win, win_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_detach = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_detach.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "base",
        type = "<any type>",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_detach",
    signature = "MPI_Win_detach(win, base, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_disp_unit = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_DISP_UNIT",
    section = "mpif-constants.h",
    type = "integer",
    value = "9",
  },
  mpi_win_dup_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_WIN_DUP_FN.3.php",
    interface = {
      {
        name = "oldwin",
        type = "integer",
      },
      {
        name = "win_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_WIN_DUP_FN",
    signature = "MPI_WIN_DUP_FN(oldwin, win_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_win_fence = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_fence.3.php",
    interface = {
      {
        intent = "in",
        name = "assert",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_fence",
    see_also = {
      "MPI_Win_create",
      "MPI_Put",
    },
    signature = "MPI_Win_fence(assert, win, ierror)",
    standard = "MPI-2.0",
    summary = "Collective synchronisation of one-sided accesses to a window",
  },
  mpi_win_flavor_allocate = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_FLAVOR_ALLOCATE",
    section = "mpif-constants.h",
    type = "integer",
    value = "2",
  },
  mpi_win_flavor_create = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_FLAVOR_CREATE",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_win_flavor_dynamic = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_FLAVOR_DYNAMIC",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
  mpi_win_flavor_shared = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_FLAVOR_SHARED",
    section = "mpif-constants.h",
    type = "integer",
    value = "4",
  },
  mpi_win_flush = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_flush.3.php",
    interface = {
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_flush",
    signature = "MPI_Win_flush(rank, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_flush_all = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_flush_all.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_flush_all",
    signature = "MPI_Win_flush_all(win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_flush_local = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_flush_local.3.php",
    interface = {
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_flush_local",
    signature = "MPI_Win_flush_local(rank, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_flush_local_all = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_flush_local_all.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_flush_local_all",
    signature = "MPI_Win_flush_local_all(win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_free = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_free.3.php",
    interface = {
      {
        intent = "inout",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_free",
    see_also = {
      "MPI_Win_create",
    },
    signature = "MPI_Win_free(win, ierror)",
    standard = "MPI-2.0",
    summary = "Release a one-sided window",
  },
  mpi_win_free_keyval = {
    binding_note = "mpi_f08 makes ierror OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_free_keyval.3.php",
    interface = {
      {
        intent = "inout",
        name = "win_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_free_keyval",
    signature = "MPI_Win_free_keyval(win_keyval, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_get_attr = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_get_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "win_keyval",
        type = "integer",
      },
      {
        intent = "out",
        name = "attribute_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_get_attr",
    signature = "MPI_Win_get_attr(win, win_keyval, attribute_val, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_get_errhandler = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_get_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_get_errhandler",
    signature = "MPI_Win_get_errhandler(win, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_get_group = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and group as type(MPI_Group); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_get_group.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "group",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_get_group",
    signature = "MPI_Win_get_group(win, group, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_get_info = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_get_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_get_info",
    signature = "MPI_Win_get_info(comm, info, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_get_name = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_get_name.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "win_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "resultlen",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_get_name",
    signature = "MPI_Win_get_name(win, win_name, resultlen, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_lock = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_lock.3.php",
    interface = {
      {
        intent = "in",
        name = "lock_type",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "assert",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_lock",
    signature = "MPI_Win_lock(lock_type, rank, assert, win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_lock_all = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_lock_all.3.php",
    interface = {
      {
        intent = "in",
        name = "assert",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_lock_all",
    signature = "MPI_Win_lock_all(assert, win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_model = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_MODEL",
    section = "mpif-constants.h",
    type = "integer",
    value = "11",
  },
  mpi_win_null = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-handles.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_NULL",
    section = "mpif-handles.h",
    type = "integer",
    value = "0",
  },
  mpi_win_null_copy_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_WIN_NULL_COPY_FN.3.php",
    interface = {
      {
        name = "window",
        type = "integer",
      },
      {
        name = "win_keyval",
        type = "integer",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "attribute_val_in",
        type = "integer(8)",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "flag",
        type = "logical",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_WIN_NULL_COPY_FN",
    signature = "MPI_WIN_NULL_COPY_FN(window, win_keyval, extra_state, attribute_val_in, attribute_val_out, flag, ierr)",
    standard = "MPI-2.0",
  },
  mpi_win_null_delete_fn = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_WIN_NULL_DELETE_FN.3.php",
    interface = {
      {
        name = "window",
        type = "integer",
      },
      {
        name = "win_keyval",
        type = "integer",
      },
      {
        name = "attribute_val_out",
        type = "integer(8)",
      },
      {
        name = "extra_state",
        type = "integer(8)",
      },
      {
        name = "ierr",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_WIN_NULL_DELETE_FN",
    signature = "MPI_WIN_NULL_DELETE_FN(window, win_keyval, attribute_val_out, extra_state, ierr)",
    standard = "MPI-2.0",
  },
  mpi_win_post = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_post.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "assert",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_post",
    signature = "MPI_Win_post(group, assert, win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_separate = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_SEPARATE",
    section = "mpif-constants.h",
    type = "integer",
    value = "1",
  },
  mpi_win_set_attr = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_set_attr.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "win_keyval",
        type = "integer",
      },
      {
        intent = "in",
        name = "attribute_val",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_set_attr",
    signature = "MPI_Win_set_attr(win, win_keyval, attribute_val, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_set_errhandler = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and errhandler as type(MPI_Errhandler); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_set_errhandler.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "errhandler",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_set_errhandler",
    signature = "MPI_Win_set_errhandler(win, errhandler, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_set_info = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and info as type(MPI_Info); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_set_info.3.php",
    interface = {
      {
        intent = "in",
        name = "comm",
        type = "integer",
      },
      {
        intent = "in",
        name = "info",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_set_info",
    signature = "MPI_Win_set_info(comm, info, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_set_name = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_set_name.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "win_name",
        type = "character(len=*)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_set_name",
    signature = "MPI_Win_set_name(win, win_name, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_shared_query = {
    binding_note = "mpi_f08 spells win as type(MPI_Win) and baseptr as type(C_ptr); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_shared_query.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "out",
        name = "size",
        type = "integer(8)",
      },
      {
        intent = "out",
        name = "disp_unit",
        type = "integer",
      },
      {
        intent = "out",
        name = "baseptr",
        type = "type(C_ptr)",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_shared_query",
    signature = "MPI_Win_shared_query(win, rank, size, disp_unit, baseptr, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_size = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_SIZE",
    section = "mpif-constants.h",
    type = "integer",
    value = "8",
  },
  mpi_win_start = {
    binding_note = "mpi_f08 spells group as type(MPI_Group) and win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_start.3.php",
    interface = {
      {
        intent = "in",
        name = "group",
        type = "integer",
      },
      {
        intent = "in",
        name = "assert",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_start",
    signature = "MPI_Win_start(group, assert, win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_sync = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_sync.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_sync",
    signature = "MPI_Win_sync(win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_test = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_test.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "flag",
        type = "logical",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_test",
    signature = "MPI_Win_test(win, flag, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_unified = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WIN_UNIFIED",
    section = "mpif-constants.h",
    type = "integer",
    value = "0",
  },
  mpi_win_unlock = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_unlock.3.php",
    interface = {
      {
        intent = "in",
        name = "rank",
        type = "integer",
      },
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_unlock",
    signature = "MPI_Win_unlock(rank, win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_win_unlock_all = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_unlock_all.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_unlock_all",
    signature = "MPI_Win_unlock_all(win, ierror)",
    standard = "MPI-3.0",
  },
  mpi_win_wait = {
    binding_note = "mpi_f08 spells win as type(MPI_Win); ierror is OPTIONAL",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Win_wait.3.php",
    interface = {
      {
        intent = "in",
        name = "win",
        type = "integer",
      },
      {
        intent = "out",
        name = "ierror",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "mpi",
    name = "MPI_Win_wait",
    signature = "MPI_Win_wait(win, ierror)",
    standard = "MPI-2.0",
  },
  mpi_wtick = {
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Wtick.3.php",
    interface = {},
    kind = "function",
    module = "mpi",
    name = "MPI_Wtick",
    result_type = "double precision",
    see_also = {
      "MPI_Wtime",
    },
    signature = "MPI_Wtick()",
    standard = "MPI-1.0",
    summary = "Resolution of MPI_Wtime, in seconds",
  },
  mpi_wtime = {
    description = "**MPI_Wtime** returns wall-clock seconds from an unspecified origin, so\n" ..
      "only differences between two calls mean anything.\n" ..
      "\n" ..
      "Two things spoil a measurement. The clocks are per-process by default, so\n" ..
      "differences taken across ranks are not comparable; and without a barrier\n" ..
      "before the first call the timing includes whatever skew the ranks arrived\n" ..
      "with. Bracket the region with MPI_Barrier to measure the region rather than\n" ..
      "the imbalance.\n" ..
      "\n" ..
      "Being a function with no arguments, it must be declared DOUBLE PRECISION when\n" ..
      "IMPLICIT NONE is in force and mpif.h is used.",
    example = "  double precision :: t0, t1\n" ..
      "\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  t0 = MPI_Wtime()\n" ..
      "  call compute_forces()\n" ..
      "  call MPI_Barrier(MPI_COMM_WORLD, ierr)\n" ..
      "  t1 = MPI_Wtime()\n" ..
      "\n" ..
      "  if (rank == 0) print *, 'forces: ', t1 - t0, ' s'",
    href = "https://www.open-mpi.org/doc/current/man3/MPI_Wtime.3.php",
    interface = {},
    kind = "function",
    module = "mpi",
    name = "MPI_Wtime",
    result = "Wall-clock seconds as DOUBLE PRECISION, measured from an arbitrary origin.",
    result_type = "double precision",
    see_also = {
      "MPI_Barrier",
      "MPI_Wtick",
    },
    signature = "MPI_Wtime()",
    standard = "MPI-1.0",
    summary = "Elapsed wall-clock time in seconds",
  },
  mpi_wtime_is_global = {
    binding_note = "value as installed here (Open MPI 5.0.10, mpif-constants.h)",
    kind = "constant",
    module = "mpi",
    name = "MPI_WTIME_IS_GLOBAL",
    section = "mpif-constants.h",
    type = "integer",
    value = "3",
  },
}
