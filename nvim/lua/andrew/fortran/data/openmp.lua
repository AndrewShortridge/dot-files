return {
  _meta = {
    generator = "snippets/gen-omp.lua",
    overrides = "snippets/overrides/openmp.lua",
    source = "$(gfortran -print-file-name=finclude)/omp_lib.f90",
    source_version = "GCC 14.3.0",
  },
  acq_rel = {
    description = "The operation acquires (no later memory access may be reordered before it) and\n" ..
      "releases (no earlier access may be reordered after it). It is the right ordering\n" ..
      "for an atomic CAPTURE that both publishes and consumes — a work-stealing counter,\n" ..
      "a hand-off flag.\n" ..
      "\n" ..
      "Cheaper than `SEQ_CST` because it does not impose a single global order over all\n" ..
      "atomics, and stronger than `RELAXED`, which orders nothing.",
    example = "!$omp atomic capture acq_rel\n" ..
      "next = index\n" ..
      "index = index + 1\n" ..
      "!$omp end atomic",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "ACQ_REL",
    see_also = {
      "ACQUIRE",
      "RELEASE",
      "SEQ_CST",
      "ATOMIC",
      "FLUSH",
    },
    signature = "ACQ_REL",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Memory order: acquire and release combined, for read-modify-write operations",
    valid_on = {
      "ATOMIC",
      "FLUSH",
    },
  },
  acquire = {
    description = "The consumer half of a release/acquire pair. A thread that reads a flag with\n" ..
      "`ACQUIRE` ordering is guaranteed to see everything the releasing thread wrote\n" ..
      "before it set the flag.\n" ..
      "\n" ..
      "Valid on atomic READ and CAPTURE operations and on `FLUSH`. It is not valid on an\n" ..
      "atomic WRITE — a pure store cannot acquire.\n" ..
      "\n" ..
      "Pair it with a `RELEASE` on the writer; an acquire with no matching release orders\n" ..
      "nothing useful.",
    example = "!$omp atomic read acquire\n" ..
      "local_flag = flag",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "ACQUIRE",
    see_also = {
      "RELEASE",
      "ACQ_REL",
      "SEQ_CST",
      "ATOMIC",
      "FLUSH",
    },
    signature = "ACQUIRE",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Memory order: no memory operation after this one may be reordered before it",
    valid_on = {
      "ATOMIC",
      "FLUSH",
    },
  },
  affinity = {
    description = "Names the data the task will mostly touch, so the runtime can schedule it on a\n" ..
      "thread whose place is close to where that data lives — which on a NUMA node is the\n" ..
      "difference between local and remote memory bandwidth.\n" ..
      "\n" ..
      "It is purely a hint and may be ignored. An `iterator` modifier allows a list whose\n" ..
      "length depends on a loop variable.\n" ..
      "\n" ..
      "Introduced in OpenMP 5.0; support is thin, and first-touch placement plus\n" ..
      "`PROC_BIND` remains the reliable way to get NUMA locality.",
    example = "!$omp task affinity(a(i:i+m))\n" ..
      "call update_block(a, i, m)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "AFFINITY",
    see_also = {
      "TASK",
      "PROC_BIND",
      "DEPEND",
    },
    signature = "AFFINITY([aff-modifier:] list)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Hint that a task should run near the given data",
    valid_on = {
      "TASK",
    },
  },
  aligned = {
    description = "Aligned vector loads and stores are faster than unaligned ones, and the compiler\n" ..
      "cannot prove alignment for a dummy argument or an allocatable. `ALIGNED(x, y: 64)`\n" ..
      "promises 64-byte alignment (a cache line, and the AVX-512 vector width).\n" ..
      "\n" ..
      "The promise must be true at run time. gfortran does not check it, and an unaligned\n" ..
      "aligned-load is a SIGSEGV or SIGBUS on some architectures and silent slowness on\n" ..
      "others. Allocate with an aligned allocator, or use compiler directives\n" ..
      "(`!GCC$ ATTRIBUTES ALIGNED`) to guarantee it.\n" ..
      "\n" ..
      "The alignment defaults to an implementation-defined value if omitted.",
    example = "!$omp simd aligned(x, y: 64)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = y(i) + a * x(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "ALIGNED",
    see_also = {
      "SIMD",
      "SIMDLEN",
      "SAFELEN",
    },
    signature = "ALIGNED(list[:alignment])",
    standard = "OpenMP 5.2",
    summary = "Promise that the listed arrays are aligned to the given byte boundary",
    valid_on = {
      "SIMD",
      "DO SIMD",
      "DECLARE SIMD",
    },
  },
  allocate = {
    description = "Says which OpenMP memory allocator provides the storage for the listed variables\n" ..
      "when the construct privatises them. The predefined allocators come from `omp_lib`:\n" ..
      "`omp_default_mem_alloc`, `omp_high_bw_mem_alloc` (high-bandwidth memory),\n" ..
      "`omp_large_cap_mem_alloc`, `omp_const_mem_alloc`, `omp_low_lat_mem_alloc`,\n" ..
      "`omp_cgroup_mem_alloc`, `omp_pteam_mem_alloc` and `omp_thread_mem_alloc`; custom\n" ..
      "ones come from `omp_init_allocator` with a trait set.\n" ..
      "\n" ..
      "There is also a standalone `!$OMP ALLOCATE` directive that applies an allocator to\n" ..
      "a Fortran `allocate` statement or to a declared variable.\n" ..
      "\n" ..
      "Support varies: on a machine with no special memory the allocators all resolve to\n" ..
      "the default one, so the clause is portable but not always meaningful. Introduced in\n" ..
      "OpenMP 5.0.",
    example = "!$omp parallel private(scratch) allocate(omp_high_bw_mem_alloc: scratch)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "ALLOCATE",
    see_also = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "omp_lib",
    },
    signature = "ALLOCATE([allocator:] list)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Choose the memory allocator used for privatised variables",
    valid_on = {
      "PARALLEL",
      "DO",
      "SECTIONS",
      "SINGLE",
      "TASK",
      "TASKLOOP",
      "TEAMS",
      "TARGET",
      "DISTRIBUTE",
    },
  },
  atomic = {
    clauses = {
      "READ",
      "WRITE",
      "UPDATE",
      "CAPTURE",
      "SEQ_CST",
      "ACQ_REL",
      "ACQUIRE",
      "RELEASE",
      "RELAXED",
      "HINT",
    },
    description = "Applies to the single statement that follows and protects ONLY the read-modify-write\n" ..
      "of the named storage location — not the evaluation of the right-hand side, which\n" ..
      "may happen concurrently on other threads.\n" ..
      "\n" ..
      "The forms: `UPDATE` (the default) allows `x = x op expr` or `x = intrinsic(x, expr)`\n" ..
      "with `op` one of `+ - * / .and. .or. .eqv. .neqv.` or the intrinsics `max`, `min`,\n" ..
      "`iand`, `ior`, `ieor`; `READ` and `WRITE` make a single load or store indivisible,\n" ..
      "which matters for types wider than a machine word; `CAPTURE` performs the update\n" ..
      "and also saves the old or new value into another variable, which is how a lock-free\n" ..
      "counter hands out unique indices.\n" ..
      "\n" ..
      "Default memory ordering is `RELAXED` unless the `REQUIRES ATOMIC_DEFAULT_MEM_ORDER`\n" ..
      "directive says otherwise; `SEQ_CST`, `ACQUIRE`, `RELEASE` and `ACQ_REL` (OpenMP 5.0)\n" ..
      "add the fence semantics. A relaxed atomic guarantees indivisibility, NOT visibility\n" ..
      "ordering of other variables.\n" ..
      "\n" ..
      "Prefer `REDUCTION` for accumulation across a loop: an atomic in an inner loop still\n" ..
      "costs a locked instruction and cache-line ping-pong on every iteration.",
    example = "!$omp parallel do\n" ..
      "do i = 1, n\n" ..
      "  !$omp atomic update\n" ..
      "  hist(bin(i)) = hist(bin(i)) + 1\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "ATOMIC",
    params = {
      acq_rel = "Acquire-release memory ordering for capture operations.",
      acquire = "Acquire memory ordering for read operations.",
      ["hint(hint-expression)"] = "OpenMP 5.0+ hint about contention (uncontended, contended, nonspeculative, speculative).",
      read = "Atomically reads the value of x into v. Syntax: `v = x`",
      relaxed = "Relaxed memory ordering. No synchronization with other operations.",
      release = "Release memory ordering for write and update operations.",
      seq_cst = "Sequentially consistent memory ordering. Provides the strongest ordering guarantees.",
      ["update** (default)\n  : Atomically updates x using an operation. Syntax: `x = x op expr` or `x = intrinsic(x, expr)`. Supported operations:\n  - Arithmetic: x = x + expr, x = x - expr, x = x * expr, x = x / expr\n  - Intrinsic: x = max(x, expr), x = min(x, expr)\n  - Bitwise: x = iand(x, expr), x = ior(x, expr), x = ieor(x, expr)\n  - Unary: x = x + 1, x = x - 1 (increment/decrement)\n\n- **capture"] = "Atomically updates x and captures either the original or final value. Requires `!$omp end atomic`. Syntax: `v = x; x = x op expr` or `v = x; x = expr; !$omp end atomic`",
      write = "Atomically writes the value of expr to x. Syntax: `x = expr`",
    },
    result = "The atomic construct ensures that the specified memory operation on x completes without interference from other threads. For update operations, the final value of x reflects the atomic combination of all thread updates. For capture operations, v contains the captured value as specified.",
    see_also = {
      "CRITICAL",
      "REDUCTION",
      "CAPTURE",
      "FLUSH",
      "SEQ_CST",
    },
    signature = "!$OMP ATOMIC [READ|WRITE|UPDATE|CAPTURE] [memory-order] [HINT(h)]",
    standard = "OpenMP 5.2",
    summary = "Perform one memory update indivisibly, without a full critical region",
  },
  barrier = {
    clauses = {},
    description = "A standalone directive: no clauses, no block. It synchronises the team and flushes\n" ..
      "memory, so writes made before the barrier by any thread are visible to all after\n" ..
      "it.\n" ..
      "\n" ..
      "**Every thread in the team must reach the same barrier, the same number of times.**\n" ..
      "A barrier inside an `if` that only some threads take, or inside a worksharing\n" ..
      "region, hangs the program — this is the classic OpenMP deadlock. For the same\n" ..
      "reason a barrier may not appear inside `DO`, `SECTIONS`, `SINGLE`, `MASTER`,\n" ..
      "`MASKED`, `CRITICAL`, `TASK` or `ORDERED`.\n" ..
      "\n" ..
      "Most barriers are implicit and free: at the end of `PARALLEL`, and at the end of\n" ..
      "every worksharing construct unless `NOWAIT` is given. Write an explicit `BARRIER`\n" ..
      "only where those do not line up — typically after a `MASTER`/`MASKED` block, or\n" ..
      "between two phases inside one parallel region.",
    example = "!$omp parallel\n" ..
      "call phase_one(a)\n" ..
      "!$omp barrier\n" ..
      "call phase_two(a)\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "BARRIER",
    result = "When all threads have reached the barrier, the synchronization is complete. All memory operations performed before the barrier by any thread are guaranteed to be visible to all threads after the barrier. Execution resumes with all threads synchronized at the same point in the program. The barrier establishes a happens-before relationship between code preceding and following the barrier across all threads.",
    see_also = {
      "NOWAIT",
      "FLUSH",
      "TASKWAIT",
      "MASKED",
    },
    signature = "!$OMP BARRIER",
    standard = "OpenMP 5.2",
    summary = "All threads of the team wait here until every thread has arrived",
  },
  bind = {
    description = "`BIND(THREAD)` makes the loop execute within one thread (vector-level work),\n" ..
      "`BIND(PARALLEL)` spreads it over the threads of the innermost enclosing parallel\n" ..
      "region, and `BIND(TEAMS)` over the primary threads of the enclosing league.\n" ..
      "\n" ..
      "Without the clause the binding is deduced from the enclosing region, which is fine\n" ..
      "inside `TARGET TEAMS` but ambiguous in an orphaned `LOOP` — so state it whenever\n" ..
      "the construct is not lexically inside the region it belongs to.\n" ..
      "\n" ..
      "Only the `LOOP` construct takes this clause.",
    example = "!$omp target teams\n" ..
      "!$omp loop bind(teams)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do\n" ..
      "!$omp end target teams",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "BIND",
    see_also = {
      "LOOP",
      "TEAMS",
      "ORDER",
    },
    signature = "BIND(TEAMS | PARALLEL | THREAD)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "State which level of parallelism a LOOP construct binds to",
    valid_on = {
      "LOOP",
    },
  },
  cancel = {
    clauses = {
      "IF",
      "PARALLEL",
      "SECTIONS",
      "DO",
      "TASKGROUP",
    },
    description = "Requests early termination of the innermost enclosing region of the named type —\n" ..
      "`PARALLEL`, `SECTIONS`, `DO` or `TASKGROUP`. The canonical use is a parallel\n" ..
      "search that stops once an answer is found.\n" ..
      "\n" ..
      "Cancellation is **off unless `OMP_CANCELLATION=true`** is set in the environment;\n" ..
      "otherwise the directive is a no-op and the loop runs to the end. That is the first\n" ..
      "thing to check when a cancel appears to do nothing. `omp_get_cancellation()`\n" ..
      "reports the setting at run time.\n" ..
      "\n" ..
      "Threads do not stop where they are: a cancelled region only ends at a\n" ..
      "CANCELLATION POINT — the `CANCEL` directive itself, an explicit\n" ..
      "`!$OMP CANCELLATION POINT`, or an implicit one such as a barrier. Long-running\n" ..
      "iterations must therefore poll with `CANCELLATION POINT` to notice.\n" ..
      "\n" ..
      "Cancelling a `DO` or `SECTIONS` construct cancels only the worksharing region, not\n" ..
      "the team; the threads continue after it. Enabling cancellation has a measurable\n" ..
      "cost on every barrier, which is why it is opt-in.",
    example = "!$omp parallel do shared(found)\n" ..
      "do i = 1, n\n" ..
      "  if (match(i)) then\n" ..
      "    found = i\n" ..
      "    !$omp cancel do\n" ..
      "  end if\n" ..
      "  !$omp cancellation point do\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "CANCEL",
    see_also = {
      "CANCELLATION POINT",
      "omp_get_cancellation",
      "TASKGROUP",
    },
    signature = "!$OMP CANCEL construct-type [IF(expr)]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Request early termination of the innermost enclosing region of the named type",
  },
  cancellation_point = {
    clauses = {},
    description = "A standalone directive marking a place where a thread checks whether cancellation\n" ..
      "of the named construct type has been requested, and if so leaves the region. It is\n" ..
      "how a long iteration notices a `CANCEL` issued by another thread.\n" ..
      "\n" ..
      "Without at least one cancellation point in the body — implicit ones exist at\n" ..
      "barriers and at `CANCEL` itself — a cancellation request is not observed until the\n" ..
      "end of the region, which defeats the purpose.\n" ..
      "\n" ..
      "Like `CANCEL`, it does nothing unless `OMP_CANCELLATION=true`.",
    example = "do i = 1, n\n" ..
      "  !$omp cancellation point do\n" ..
      "  call expensive(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "CANCELLATION POINT",
    see_also = {
      "CANCEL",
      "omp_get_cancellation",
    },
    signature = "!$OMP CANCELLATION POINT construct-type",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Mark a point at which a thread checks for a pending cancellation request",
  },
  capture = {
    description = "`!$OMP ATOMIC CAPTURE` applies to a pair of statements (or one statement) that both\n" ..
      "update `x` and record a value: `v = x; x = x + 1` captures the OLD value,\n" ..
      "`x = x + 1; v = x` the NEW one. The block form is closed by `!$OMP END ATOMIC`.\n" ..
      "\n" ..
      "This is the lock-free counter: every thread that executes it receives a distinct\n" ..
      "index, with no critical region. It is how work queues hand out items and how a\n" ..
      "shared output array is appended to.\n" ..
      "\n" ..
      "Add `ACQ_REL` or `SEQ_CST` when the captured value also publishes or consumes other\n" ..
      "data.",
    example = "!$omp atomic capture\n" ..
      "my_index = next_free\n" ..
      "next_free = next_free + 1\n" ..
      "!$omp end atomic",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "CAPTURE",
    see_also = {
      "ATOMIC",
      "UPDATE",
      "ACQ_REL",
      "CRITICAL",
    },
    signature = "CAPTURE",
    standard = "OpenMP 5.2",
    summary = "ATOMIC form: perform an update and save the old or new value",
    valid_on = {
      "ATOMIC",
    },
  },
  collapse = {
    description = "With `COLLAPSE(2)` the two loop nests become a single iteration space of\n" ..
      "`n1 * n2` iterations, which is then divided among threads. It is the fix for a\n" ..
      "parallel outer loop that is too short to fill the team — a `do j = 1, 4` nest over\n" ..
      "`do i = 1, 1000000` gives four-way parallelism without it and four million\n" ..
      "iterations of work with it.\n" ..
      "\n" ..
      "The loops must be PERFECTLY nested: no statements between them, and the inner\n" ..
      "bounds must not depend on the outer index (so a triangular nest cannot be\n" ..
      "collapsed). All the collapsed indices are private automatically.\n" ..
      "\n" ..
      "The cost is index arithmetic — the runtime recovers i and j from a linear index —\n" ..
      "and the loss of the inner loop's contiguity when the compiler cannot undo the\n" ..
      "fusion. For a nest whose inner loop is already long, collapsing usually loses.",
    example = "!$omp parallel do collapse(2) private(i, j)\n" ..
      "do j = 1, ny\n" ..
      "  do i = 1, nx\n" ..
      "    a(i, j) = f(i, j)\n" ..
      "  end do\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "COLLAPSE",
    see_also = {
      "DO",
      "SCHEDULE",
      "ORDER",
      "LOOP",
    },
    signature = "COLLAPSE(n)",
    standard = "OpenMP 5.2",
    summary = "Fuse the n outermost perfectly nested loops into one iteration space",
    valid_on = {
      "DO",
      "SIMD",
      "DO SIMD",
      "TASKLOOP",
      "DISTRIBUTE",
      "LOOP",
    },
  },
  copyin = {
    description = "Applies only to `THREADPRIVATE` variables and common blocks. At the start of the\n" ..
      "parallel region each thread's copy is assigned the value the PRIMARY thread's copy\n" ..
      "has — the standard way to initialise per-thread state that was set up in the serial\n" ..
      "part of the program.\n" ..
      "\n" ..
      "Without it, a thread's threadprivate copy on first entry to a parallel region is\n" ..
      "undefined (it is only guaranteed to persist between regions under the conditions\n" ..
      "listed in `THREADPRIVATE`).\n" ..
      "\n" ..
      "For a common block, name the block: `COPYIN(/params/)`. For an allocatable\n" ..
      "threadprivate variable, the primary thread's copy must be allocated and the\n" ..
      "copies take its value by intrinsic assignment.",
    example = "!$omp parallel copyin(/params/)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "COPYIN",
    see_also = {
      "THREADPRIVATE",
      "FIRSTPRIVATE",
      "COPYPRIVATE",
    },
    signature = "COPYIN(list)",
    standard = "OpenMP 5.2",
    summary = "Broadcast the primary thread's THREADPRIVATE values to the whole team",
    valid_on = {
      "PARALLEL",
      "PARALLEL DO",
      "PARALLEL SECTIONS",
      "PARALLEL WORKSHARE",
    },
  },
  copyprivate = {
    description = "Written on `!$OMP END SINGLE`. The values the executing thread assigned to the\n" ..
      "listed variables are copied to every other thread's corresponding variable, which\n" ..
      "must be private or threadprivate in each of them.\n" ..
      "\n" ..
      "It is the clean answer to 'one thread reads the input file, everybody needs the\n" ..
      "result': no shared variable, no extra barrier, no race. The broadcast happens at\n" ..
      "the single construct's implicit barrier, so `COPYPRIVATE` and `NOWAIT` are\n" ..
      "mutually exclusive.\n" ..
      "\n" ..
      "A pointer may be copied (giving every thread the same target), and an allocatable\n" ..
      "must be allocated with the same shape in every thread.",
    example = "!$omp single\n" ..
      "read(unit, *) nsteps\n" ..
      "!$omp end single copyprivate(nsteps)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "COPYPRIVATE",
    see_also = {
      "SINGLE",
      "COPYIN",
      "NOWAIT",
    },
    signature = "COPYPRIVATE(list)",
    standard = "OpenMP 5.2",
    summary = "Broadcast values from the thread that executed a SINGLE block to the whole team",
    valid_on = {
      "END SINGLE",
    },
  },
  critical = {
    clauses = {
      "HINT",
    },
    description = "All threads that reach the construct execute it, one at a time, in unspecified\n" ..
      "order. `!$OMP END CRITICAL [(name)]` closes it and the name, if given, must match.\n" ..
      "\n" ..
      "The name matters more than it looks: all UNNAMED critical constructs in the whole\n" ..
      "program share one lock, including those inside libraries you did not write. Two\n" ..
      "unrelated unnamed critical regions therefore serialise against each other. Give\n" ..
      "every critical region a name unless it really is the one global lock.\n" ..
      "\n" ..
      "A critical region is a full memory fence at entry and exit, and it does not scale:\n" ..
      "n threads take n times the region's length. For a single-variable update use\n" ..
      "`ATOMIC`, which a modern CPU does with one instruction; for accumulation use\n" ..
      "`REDUCTION`, which needs no synchronisation in the loop at all.\n" ..
      "\n" ..
      "`HINT(omp_sync_hint_contended)` and friends (OpenMP 4.5, renamed from\n" ..
      "`omp_lock_hint_*` in 5.0) let the implementation pick a lock implementation.\n" ..
      "Blocking calls or `exit`/`goto` out of a critical region are invalid and deadlock.",
    example = "!$omp parallel do\n" ..
      "do i = 1, n\n" ..
      "  call work(i, hit)\n" ..
      "  !$omp critical (tally)\n" ..
      "  count = count + hit\n" ..
      "  !$omp end critical (tally)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "CRITICAL",
    params = {
      ["hint(hint-expression)"] = "Optional clause providing implementation hints about expected runtime properties. Valid hint values (from `omp_lib` module): - `omp_sync_hint_none` (default) - No hint specified - `omp_sync_hint_uncontended` - Low contention expected - `omp_sync_hint_contended` - High contention expected - `omp_sync_hint_nonspeculative` - Use non-speculative locking - `omp_sync_hint_speculative` - Use speculative locking (hardware transactional memory) Hints do not affect isolation guarantees and may be ignored by the implementation. A hint clause requires a named construct.",
      name = "Optional identifier for the critical region. Names are global entities of the program in Fortran. Critical regions with the same name share mutual exclusion. If omitted, the critical section shares an implicit common name with all other unnamed critical sections.",
    },
    result = "The critical construct ensures that only one thread at a time executes the enclosed structured block. Upon exiting the critical region, the thread releases the lock, allowing another waiting thread to enter. All memory operations within the critical region are protected from concurrent access by other threads entering the same named (or unnamed) critical region.",
    see_also = {
      "ATOMIC",
      "REDUCTION",
      "HINT",
      "omp_set_lock",
    },
    signature = "!$OMP CRITICAL [(name)] [HINT(hint-expr)]",
    standard = "OpenMP 5.2",
    summary = "Mutual exclusion: at most one thread at a time executes the block",
  },
  declare_reduction = {
    clauses = {},
    description = "Extends `REDUCTION` to derived types and to operations the standard list lacks.\n" ..
      "The combiner is an expression or assignment written in terms of the special names\n" ..
      "`omp_in` and `omp_out` — it must combine `omp_in` into `omp_out`. The\n" ..
      "`INITIALIZER` clause defines the private copy's starting value in terms of\n" ..
      "`omp_priv` (and may use `omp_orig` for the value before the region).\n" ..
      "\n" ..
      "The declaration is a declarative directive and is scoped like a Fortran\n" ..
      "declaration: put it in a module next to the type it serves and it is available\n" ..
      "wherever that module is used.\n" ..
      "\n" ..
      "The combiner must be associative and commutative in practice, because the order in\n" ..
      "which partial results are merged is unspecified — the same caveat that makes a\n" ..
      "floating-point reduction non-reproducible run to run.",
    example = "!$omp declare reduction(vecadd : vec_t : omp_out = omp_out + omp_in) &\n" ..
      "!$omp   initializer(omp_priv = vec_zero())\n" ..
      "\n" ..
      "!$omp parallel do reduction(vecadd : total)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DECLARE REDUCTION",
    see_also = {
      "REDUCTION",
      "IN_REDUCTION",
      "TASK_REDUCTION",
    },
    signature = "!$OMP DECLARE REDUCTION(identifier : type-list : combiner) [INITIALIZER(initializer-expr)]",
    standard = "OpenMP 5.2",
    summary = "Define a user reduction operator for types the built-in operators do not cover",
  },
  declare_simd = {
    clauses = {
      "SIMDLEN",
      "LINEAR",
      "ALIGNED",
      "UNIFORM",
      "INBRANCH",
      "NOTINBRANCH",
    },
    description = "Placed in the procedure's own specification part (or in an interface body), it\n" ..
      "tells the compiler to emit an additional, vector-argument version of the routine.\n" ..
      "A call inside a `SIMD` loop can then be vectorised instead of forcing a scalar\n" ..
      "fallback.\n" ..
      "\n" ..
      "`UNIFORM(list)` marks arguments that are the same for every lane (a scalar\n" ..
      "parameter, a pointer); `LINEAR(list[:step])` marks ones that advance by a constant\n" ..
      "per iteration (an index); `ALIGNED` promises alignment; `INBRANCH` /\n" ..
      "`NOTINBRANCH` say whether the routine is ever called under a mask.\n" ..
      "\n" ..
      "The procedure body must be safe to execute for several lanes at once: no I/O, no\n" ..
      "shared state, ideally `pure`. Introduced in OpenMP 4.0.",
    example = "pure function kernel(x) result(y)\n" ..
      "  !$omp declare simd(kernel) uniform(a) notinbranch\n" ..
      "  real(dp), intent(in) :: x\n" ..
      "  real(dp) :: y\n" ..
      "  y = x * x\n" ..
      "end function",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DECLARE SIMD",
    see_also = {
      "SIMD",
      "DO SIMD",
      "SIMDLEN",
      "ALIGNED",
      "LINEAR",
    },
    signature = "!$OMP DECLARE SIMD(proc-name) [clauses]",
    standard = "OpenMP 5.2",
    summary = "Generate a SIMD version of a procedure so it can be called from vectorised loops",
  },
  declare_target = {
    clauses = {
      "ENTER",
      "TO",
      "LINK",
      "DEVICE_TYPE",
      "INDIRECT",
    },
    description = "A declarative directive that makes procedures and variables available inside\n" ..
      "`TARGET` regions. A procedure called from device code MUST be declared this way,\n" ..
      "or the link step fails with an unresolved symbol from the device compiler — the\n" ..
      "most common first error when offloading existing Fortran.\n" ..
      "\n" ..
      "`ENTER(list)` (called `TO(list)` before OpenMP 5.2, still accepted) creates a\n" ..
      "device copy of a variable at program start; `LINK(list)` declares the variable as\n" ..
      "mappable but leaves the copy to be created when a `MAP` clause names it, which\n" ..
      "suits large tables. `DEVICE_TYPE(HOST|NOHOST|ANY)` restricts where the version is\n" ..
      "generated.\n" ..
      "\n" ..
      "Put the directive in the procedure's own specification part, or list the names in\n" ..
      "a module's specification part. Everything the declared procedure calls must itself\n" ..
      "be declared target.",
    example = "module kernels\n" ..
      "  real(dp) :: table(256)\n" ..
      "  !$omp declare target enter(table)\n" ..
      "contains\n" ..
      "  pure function f(x) result(y)\n" ..
      "    !$omp declare target\n" ..
      "    real(dp), intent(in) :: x\n" ..
      "    real(dp) :: y\n" ..
      "    y = x * x\n" ..
      "  end function\n" ..
      "end module",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DECLARE TARGET",
    see_also = {
      "TARGET",
      "MAP",
      "DECLARE SIMD",
      "METADIRECTIVE",
    },
    signature = "!$OMP DECLARE TARGET [(list)] [ENTER(list)] [LINK(list)] [DEVICE_TYPE(...)]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Make procedures and variables available inside TARGET regions",
  },
  default = {
    description = "**Use `DEFAULT(NONE)`.** It forces every variable referenced in the region to be\n" ..
      "named in an explicit data-sharing clause, so a forgotten `PRIVATE` becomes a\n" ..
      "compile error instead of a race that shows up on 64 threads six months later. It\n" ..
      "is the single highest-value habit in OpenMP Fortran.\n" ..
      "\n" ..
      "`DEFAULT(SHARED)` restores the standard default. `DEFAULT(PRIVATE)` is a\n" ..
      "Fortran-only option (there is no C equivalent) and `DEFAULT(FIRSTPRIVATE)` was\n" ..
      "added in OpenMP 5.0; both are occasionally convenient and both hide exactly the\n" ..
      "mistakes `NONE` exposes.\n" ..
      "\n" ..
      "`DEFAULT(NONE)` does not apply to variables with a predetermined attribute — loop\n" ..
      "indices, `THREADPRIVATE` variables, named constants — so those need not be listed.",
    example = "!$omp parallel do default(none) shared(a, b, n) private(i, tmp)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "DEFAULT",
    see_also = {
      "SHARED",
      "PRIVATE",
      "FIRSTPRIVATE",
    },
    signature = "DEFAULT(NONE | SHARED | PRIVATE | FIRSTPRIVATE)",
    standard = "OpenMP 5.2 §5.4.1",
    summary = "Set the data-sharing attribute for variables not named in another clause",
    valid_on = {
      "PARALLEL",
      "TASK",
      "TASKLOOP",
      "TEAMS",
      "TARGET",
    },
  },
  depend = {
    description = "The dependence types: `IN` (this task reads the item — it waits for earlier\n" ..
      "sibling tasks with `OUT` or `INOUT` on it), `OUT` and `INOUT` (this task writes it\n" ..
      "— it waits for all earlier siblings that touch it), `MUTEXINOUTSET` (OpenMP 5.0 —\n" ..
      "the tasks in the set exclude each other but may run in any order, which is a\n" ..
      "reduction-like pattern without an order constraint), and `DEPOBJ` (take the\n" ..
      "dependence from a dependence object).\n" ..
      "\n" ..
      "Dependences are matched by the STORAGE the list item denotes, and only between\n" ..
      "SIBLING tasks — tasks generated by the same parent. A dependence on a variable\n" ..
      "touched by a task in a different parent is not seen, which is the usual reason a\n" ..
      "dependence graph does not do what it looks like it should.\n" ..
      "\n" ..
      "Array sections are allowed (`depend(in: a(1:n/2))`) and are matched by identical\n" ..
      "storage: two sections that merely overlap do not create a dependence in OpenMP 5.x\n" ..
      "unless they denote the same storage, so partial overlaps are a correctness hazard.\n" ..
      "\n" ..
      "This is the mechanism behind task-based linear algebra: express the DAG of tile\n" ..
      "operations and let the runtime schedule it, with no barriers at all.",
    example = "!$omp task depend(out: a)\n" ..
      "call produce(a)\n" ..
      "!$omp end task\n" ..
      "!$omp task depend(in: a) depend(inout: b)\n" ..
      "call consume(a, b)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "DEPEND",
    see_also = {
      "TASK",
      "TASKWAIT",
      "DEPOBJ",
      "TASKGROUP",
      "ORDERED",
    },
    signature = "DEPEND([modifier,] dependence-type : list)",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Order tasks by the data they read and write instead of by barriers",
    valid_on = {
      "TASK",
      "TASKLOOP",
      "TARGET",
      "TARGET UPDATE",
      "TASKWAIT",
      "ORDERED",
      "DEPOBJ",
    },
  },
  depobj = {
    clauses = {
      "DEPEND",
      "UPDATE",
      "DESTROY",
    },
    description = "Builds a reusable DEPENDENCE OBJECT — a variable of kind `omp_depend_kind` from\n" ..
      "`omp_lib_kinds` — that stores a dependence, so it can be attached to many tasks\n" ..
      "with `DEPEND(DEPOBJ: obj)` instead of repeating a long variable list.\n" ..
      "\n" ..
      "Three forms: initialisation with a `DEPEND` clause, `UPDATE(type)` to change the\n" ..
      "dependence type, and `DESTROY` to release it. An object must be initialised before\n" ..
      "use and destroyed exactly once.\n" ..
      "\n" ..
      "It is most useful when the dependence is computed (a neighbour list, a sparse\n" ..
      "pattern) or when the same dependence set is used by many task-generating sites.\n" ..
      "Introduced in OpenMP 5.0.",
    example = "use omp_lib_kinds, only: omp_depend_kind\n" ..
      "integer(omp_depend_kind) :: dep\n" ..
      "!$omp depobj(dep) depend(inout: a)\n" ..
      "!$omp task depend(depobj: dep)\n" ..
      "call update(a)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DEPOBJ",
    see_also = {
      "DEPEND",
      "TASK",
      "omp_lib_kinds",
    },
    signature = "!$OMP DEPOBJ(obj) DEPEND(type: list) | UPDATE(type) | DESTROY",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Create, update or destroy a reusable task dependence object",
  },
  detach = {
    description = "The task's body may return while the task itself is NOT complete: it stays pending\n" ..
      "until some thread calls `omp_fulfill_event(handle)`. Dependent tasks and enclosing\n" ..
      "taskgroups keep waiting until then.\n" ..
      "\n" ..
      "This is how asynchronous work outside OpenMP's control is integrated into the task\n" ..
      "graph — an MPI non-blocking request, a CUDA stream callback, an I/O completion. The\n" ..
      "body starts the operation and returns; the callback fulfils the event.\n" ..
      "\n" ..
      "The handle is an `integer(omp_event_handle_kind)` from `omp_lib_kinds`. Failing to\n" ..
      "fulfil the event hangs the program at the next taskgroup or barrier, with no\n" ..
      "diagnostic. Introduced in OpenMP 5.0.",
    example = "use omp_lib_kinds, only: omp_event_handle_kind\n" ..
      "integer(omp_event_handle_kind) :: ev\n" ..
      "!$omp task detach(ev)\n" ..
      "call start_async_io(ev)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "DETACH",
    see_also = {
      "TASK",
      "TASKWAIT",
      "DEPEND",
      "omp_lib_kinds",
    },
    signature = "DETACH(event-handle)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Create a detachable task that completes only when its event is fulfilled",
    valid_on = {
      "TASK",
    },
  },
  device = {
    description = "The argument is a device number in `0 .. omp_get_num_devices()-1`; without the\n" ..
      "clause the default device is used, which comes from `omp_set_default_device` or\n" ..
      "`OMP_DEFAULT_DEVICE`.\n" ..
      "\n" ..
      "`omp_get_initial_device()` returns the host's number, so `DEVICE(omp_get_initial_device())`\n" ..
      "explicitly targets the host. OpenMP 5.0 adds the `ANCESTOR` modifier, used with\n" ..
      "`REVERSE_OFFLOAD` to run a region back on the host from inside a device region.\n" ..
      "\n" ..
      "In a multi-GPU run the usual pattern is one MPI rank per device with the rank\n" ..
      "selecting its device once at start-up; mixing devices inside one rank means\n" ..
      "managing separate data environments per device, since mappings are per-device.",
    example = "call omp_set_default_device(mod(rank, omp_get_num_devices()))\n" ..
      "!$omp target device(0) map(tofrom: u)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "DEVICE",
    see_also = {
      "TARGET",
      "MAP",
      "omp_get_num_devices",
      "omp_get_device_num",
    },
    signature = "DEVICE([device-modifier:] scalar-integer-expr)",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Select which device executes the region or holds the data",
    valid_on = {
      "TARGET",
      "TARGET DATA",
      "TARGET UPDATE",
      "TARGET ENTER DATA",
      "TARGET EXIT DATA",
    },
  },
  dist_schedule = {
    description = "The only kind allowed is `STATIC`: iterations are divided into chunks of\n" ..
      "`chunk_size` and assigned to teams round-robin. Without a chunk size the\n" ..
      "implementation splits the space into one contiguous block per team.\n" ..
      "\n" ..
      "It is the `DISTRIBUTE` counterpart of `SCHEDULE`, and there is no dynamic variant —\n" ..
      "teams cannot synchronise with each other, so work stealing across them is not\n" ..
      "available.\n" ..
      "\n" ..
      "On a GPU the chunk size interacts with coalescing: a small chunk (1, or the warp\n" ..
      "size) combined with `DISTRIBUTE PARALLEL DO` usually gives neighbouring threads\n" ..
      "neighbouring array elements, which is what the memory system wants.",
    example = "!$omp distribute parallel do dist_schedule(static, 1024)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "DIST_SCHEDULE",
    see_also = {
      "DISTRIBUTE",
      "SCHEDULE",
      "TEAMS",
    },
    signature = "DIST_SCHEDULE(STATIC[, chunk_size])",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Chunking of iterations across the teams of a league",
    valid_on = {
      "DISTRIBUTE",
      "DISTRIBUTE PARALLEL DO",
    },
  },
  distribute = {
    clauses = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "COLLAPSE",
      "DIST_SCHEDULE",
      "ALLOCATE",
      "ORDER",
    },
    description = "Divides the iterations of the following loop across the PRIMARY THREADS of the\n" ..
      "teams in a league — one level coarser than `DO`, which divides across the threads\n" ..
      "of one team. It is valid only inside a `TEAMS` region.\n" ..
      "\n" ..
      "There is no implicit barrier (teams cannot synchronise with each other) and no\n" ..
      "`SCHEDULE` clause; the chunking control is `DIST_SCHEDULE(STATIC[, chunk])`.\n" ..
      "\n" ..
      "On its own it leaves each team's non-primary threads idle, so it is almost always\n" ..
      "written combined: `DISTRIBUTE PARALLEL DO` splits across teams and then across the\n" ..
      "threads within each team.",
    example = "!$omp target teams\n" ..
      "!$omp distribute parallel do dist_schedule(static, 1024)\n" ..
      "do i = 1, n\n" ..
      "  c(i) = a(i) * b(i)\n" ..
      "end do\n" ..
      "!$omp end target teams",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DISTRIBUTE",
    see_also = {
      "TEAMS",
      "DO",
      "DIST_SCHEDULE",
      "TARGET",
    },
    signature = "!$OMP DISTRIBUTE [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Divide loop iterations across the primary threads of the teams in a league",
  },
  ["do"] = {
    clauses = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "LINEAR",
      "REDUCTION",
      "SCHEDULE",
      "COLLAPSE",
      "ORDERED",
      "NOWAIT",
      "ALLOCATE",
      "ORDER",
    },
    description = "Must be immediately followed by a `do` loop in canonical form: an integer counted\n" ..
      "loop whose trip count is computable on entry. `do while` and loops with `exit`\n" ..
      "cannot be worksharing constructs.\n" ..
      "\n" ..
      "The loop iteration variable is PRIVATE automatically, as are the variables of any\n" ..
      "loops collapsed with `COLLAPSE(n)`. Everything else keeps the data-sharing\n" ..
      "attribute it has in the enclosing `PARALLEL` region, which in Fortran defaults to\n" ..
      "shared — so a scratch variable used inside the loop body is a race unless it is\n" ..
      "named in `PRIVATE`.\n" ..
      "\n" ..
      "There is an implicit barrier at the end of the loop; `NOWAIT` removes it, and is\n" ..
      "worth having when two independent loops follow one another inside one parallel\n" ..
      "region. Note that with `NOWAIT` a thread may run ahead into the next construct,\n" ..
      "so any dependence between the two loops must then be enforced by hand.\n" ..
      "\n" ..
      "`!$OMP END DO` is optional unless `NOWAIT` is attached to it. `DO` alone does not\n" ..
      "create threads: without an enclosing `PARALLEL` region it binds to a team of one\n" ..
      "and the loop runs serially.",
    example = "!$omp do schedule(static) reduction(+:total) private(tmp)\n" ..
      "do i = 1, n\n" ..
      "  tmp = f(x(i))\n" ..
      "  total = total + tmp\n" ..
      "end do\n" ..
      "!$omp end do nowait",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DO",
    params = {
      ["collapse(n)"] = "Combines n nested loops into one larger iteration space for better load balancing.",
      ["default(none|shared|private)"] = "Sets the default data-sharing attribute for variables. Using `none` is recommended as it requires explicit specification of all variables, preventing accidental sharing bugs.",
      ["firstprivate(list)"] = "Like private, but each thread's copy is initialized from the original variable's value before the parallel region begins.",
      ["if(expr)"] = "If false, the region executes serially with a single thread.",
      ["lastprivate(list)"] = "Like private, but the value from the sequentially last iteration is copied back to the original variable after the loop completes.",
      ["num_threads(expr)"] = "Specifies the number of threads for the parallel region.",
      ["private(list)"] = "Creates a new private instance of each listed variable for each thread. The initial value is undefined. At the end of the parallel region, the original variable is unchanged.",
      ["reduction(operator:list)"] = "Performs a reduction using the specified operator. Each thread has a private copy initialized appropriately (0 for +, 1 for *, etc.). At region end, partial results are combined. Operators: +, -, *, .and., .or., .eqv., .neqv., max, min, iand, ior, ieor.",
      ["schedule(type [, chunk_size])"] = "Controls iteration distribution: - `static` - Iterations divided into chunks assigned round-robin (default) - `dynamic` - Threads take chunks from a queue as they finish - `guided` - Chunk sizes decrease exponentially - `runtime` - Determined by OMP_SCHEDULE environment variable - `auto` - Compiler/runtime decides",
      ["shared(list)"] = "Specifies that listed variables are shared among all threads. All threads access the same storage location. Care must be taken to avoid race conditions.",
    },
    result = "The parallel do construct distributes loop iterations across multiple threads, achieving parallel execution of the loop body. Upon completion, all threads have executed their assigned iterations, any reduction variables contain the combined result, and lastprivate variables hold the value from the final sequential iteration.",
    see_also = {
      "PARALLEL DO",
      "SCHEDULE",
      "NOWAIT",
      "COLLAPSE",
      "REDUCTION",
    },
    signature = "!$OMP DO [clauses]",
    standard = "OpenMP 5.2",
    summary = "Worksharing: divide the iterations of the following loop among the team",
  },
  do_simd = {
    clauses = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "REDUCTION",
      "SCHEDULE",
      "COLLAPSE",
      "NOWAIT",
      "SAFELEN",
      "SIMDLEN",
      "LINEAR",
      "ALIGNED",
      "ORDER",
      "ALLOCATE",
    },
    description = "The iterations are first distributed across threads as by `DO`, then each thread's\n" ..
      "chunk is executed in SIMD lanes as by `SIMD`. It accepts the clauses of both, and\n" ..
      "`SCHEDULE` chunk sizes that are multiples of the vector length avoid remainder\n" ..
      "loops at every chunk boundary.\n" ..
      "\n" ..
      "The implicit barrier of the worksharing loop is still there unless `NOWAIT` is\n" ..
      "given. Both levels of the assertion apply: no cross-iteration dependences, and\n" ..
      "anything written in the body private.\n" ..
      "\n" ..
      "Introduced in OpenMP 4.0.",
    example = "!$omp parallel\n" ..
      "!$omp do simd schedule(static, 64)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do\n" ..
      "!$omp end do simd\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "DO SIMD",
    see_also = {
      "DO",
      "SIMD",
      "PARALLEL DO SIMD",
      "SCHEDULE",
    },
    signature = "!$OMP DO SIMD [clauses]",
    standard = "OpenMP 5.2",
    summary = "Worksharing loop whose per-thread chunks are additionally vectorised",
  },
  filter = {
    description = "The block is executed only by the thread whose `omp_get_thread_num()` equals the\n" ..
      "argument. The default, when the clause is absent, is thread 0 — which is exactly\n" ..
      "the behaviour of the deprecated `MASTER` construct.\n" ..
      "\n" ..
      "If no thread in the team matches (the number is out of range) the block is not\n" ..
      "executed at all, and no error is raised.\n" ..
      "\n" ..
      "There is no barrier, so the remaining threads run on immediately.",
    example = "!$omp masked filter(2)\n" ..
      "call log_from_one_thread()\n" ..
      "!$omp end masked",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "FILTER",
    see_also = {
      "MASKED",
      "MASTER",
      "SINGLE",
      "omp_get_thread_num",
    },
    signature = "FILTER(thread_num)",
    standard = "OpenMP 5.2 (introduced in 5.1)",
    summary = "Select which thread executes a MASKED region",
    valid_on = {
      "MASKED",
    },
  },
  final = {
    description = "A FINAL task is executed by the encountering thread without deferral, and every\n" ..
      "task generated INSIDE it is also final and undeferred — the whole subtree collapses\n" ..
      "to sequential execution.\n" ..
      "\n" ..
      "That is the standard cut-off for recursive task parallelism: below some depth or\n" ..
      "problem size the runtime overhead exceeds the work, so `FINAL(depth > cutoff)`\n" ..
      "turns the rest of the recursion into ordinary calls. `omp_in_final()` lets the body\n" ..
      "itself check and skip the task-generating code path entirely.\n" ..
      "\n" ..
      "`IF(.false.)` also forces immediate execution, but only for that one task —\n" ..
      "descendants are still deferred. `FINAL` is the one that prunes the subtree.",
    example = "!$omp task final(n < 1000) mergeable\n" ..
      "call sort(a, lo, hi)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "FINAL",
    see_also = {
      "IF",
      "MERGEABLE",
      "omp_in_final",
      "TASK",
    },
    signature = "FINAL(scalar-logical-expr)",
    standard = "OpenMP 5.2",
    summary = "When true, this task and all its descendants are executed immediately and sequentially",
    valid_on = {
      "TASK",
      "TASKLOOP",
    },
  },
  firstprivate = {
    description = "Like `PRIVATE`, but each copy starts as a copy of the original's value at the point\n" ..
      "the construct is encountered. The original is still unchanged on exit.\n" ..
      "\n" ..
      "For a derived type the initialisation is intrinsic assignment, so allocatable\n" ..
      "components are deep-copied and the copy may be expensive — firstprivatising a\n" ..
      "large array per thread in a hot loop is a real cost, not a formality.\n" ..
      "\n" ..
      "It is the DEFAULT data-sharing attribute for variables referenced in a `TASK`\n" ..
      "region that are not shared in the enclosing context: the value is captured when\n" ..
      "the task is CREATED, not when it runs, which is exactly what makes a loop index\n" ..
      "safe to use inside a task.\n" ..
      "\n" ..
      "`DEFAULT(FIRSTPRIVATE)` sets it as the default for a whole construct — a Fortran\n" ..
      "extension of the `DEFAULT` clause added in OpenMP 5.0.",
    example = "!$omp parallel do firstprivate(offset) private(i)\n" ..
      "do i = 1, n\n" ..
      "  a(i) = a(i) + offset\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "FIRSTPRIVATE",
    see_also = {
      "PRIVATE",
      "LASTPRIVATE",
      "COPYIN",
      "DEFAULT",
    },
    signature = "FIRSTPRIVATE(list)",
    standard = "OpenMP 5.2 §5.4.4",
    summary = "Private copies, each initialised from the value the variable had before the region",
    valid_on = {
      "PARALLEL",
      "DO",
      "SECTIONS",
      "SINGLE",
      "TASK",
      "TASKLOOP",
      "TARGET",
      "TEAMS",
      "DISTRIBUTE",
    },
  },
  flush = {
    clauses = {
      "ACQ_REL",
      "ACQUIRE",
      "RELEASE",
    },
    description = "A flush is a memory FENCE, not a transfer: it prevents the compiler and the\n" ..
      "hardware from moving memory operations across it and makes the thread's writes\n" ..
      "visible to other threads that also flush. With a list, only those variables are\n" ..
      "flushed; without, all thread-visible variables are.\n" ..
      "\n" ..
      "Flushes are already implied at the entry and exit of `PARALLEL`, at every\n" ..
      "`BARRIER`, at the entry and exit of worksharing constructs that have a barrier, at\n" ..
      "`CRITICAL`, `ORDERED`, locks and `ATOMIC` (for the atomic location). Writing one\n" ..
      "explicitly is only necessary when hand-rolling a synchronisation protocol — and\n" ..
      "then it must be paired: a `FLUSH` on the writer and a `FLUSH` on the reader, in\n" ..
      "that order.\n" ..
      "\n" ..
      "Since OpenMP 5.0 a flush may carry `ACQUIRE`, `RELEASE` or `ACQ_REL` to request\n" ..
      "one-directional ordering instead of a full fence. A list plus a memory-order\n" ..
      "clause is not allowed.\n" ..
      "\n" ..
      "`FLUSH` is not a substitute for mutual exclusion: it orders accesses, it does not\n" ..
      "make a read-modify-write indivisible.",
    example = "!$omp parallel shared(ready, data)\n" ..
      "!$omp masked\n" ..
      "data = compute()\n" ..
      "!$omp flush(data)\n" ..
      "ready = .true.\n" ..
      "!$omp flush(ready)\n" ..
      "!$omp end masked\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "FLUSH",
    see_also = {
      "ATOMIC",
      "BARRIER",
      "ACQUIRE",
      "RELEASE",
      "volatile",
    },
    signature = "!$OMP FLUSH [(list)] [ACQUIRE|RELEASE|ACQ_REL]",
    standard = "OpenMP 5.2",
    summary = "Make this thread's view of memory consistent with main memory",
  },
  grainsize = {
    description = "Each task created by the `TASKLOOP` gets between `grain-size` and `2*grain-size`\n" ..
      "iterations (the `STRICT` modifier, OpenMP 5.1, makes it exactly `grain-size`\n" ..
      "except for the remainder). It controls task granularity directly, where\n" ..
      "`NUM_TASKS` controls the count.\n" ..
      "\n" ..
      "Choose it so a task is worth its overhead — of the order of microseconds of work,\n" ..
      "typically hundreds of iterations of a simple body. Too fine and the runtime\n" ..
      "dominates; too coarse and the load balances badly.\n" ..
      "\n" ..
      "`GRAINSIZE` and `NUM_TASKS` are mutually exclusive.",
    example = "!$omp taskloop grainsize(256)\n" ..
      "do i = 1, n\n" ..
      "  call work(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "GRAINSIZE",
    see_also = {
      "NUM_TASKS",
      "TASKLOOP",
      "NOGROUP",
    },
    signature = "GRAINSIZE([strict:] grain-size)",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Request at least this many loop iterations per generated task",
    valid_on = {
      "TASKLOOP",
    },
  },
  hint = {
    description = "The constants come from `omp_lib`: `omp_sync_hint_none`,\n" ..
      "`omp_sync_hint_uncontended`, `omp_sync_hint_contended`,\n" ..
      "`omp_sync_hint_speculative` and `omp_sync_hint_nonspeculative` (renamed in OpenMP\n" ..
      "5.0 from `omp_lock_hint_*`, which are still defined as synonyms). They may be\n" ..
      "combined with `+` or `ior`.\n" ..
      "\n" ..
      "`SPECULATIVE` asks for hardware transactional memory where available, which can\n" ..
      "make a contended critical region nearly free when conflicts are rare.\n" ..
      "`UNCONTENDED` asks for the cheapest possible lock.\n" ..
      "\n" ..
      "It is only a hint: semantics are unchanged and an implementation may ignore it.\n" ..
      "A named `CRITICAL` construct must use the same hint everywhere it appears.",
    example = "!$omp critical (tally) hint(omp_sync_hint_contended)\n" ..
      "count = count + 1\n" ..
      "!$omp end critical (tally)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "HINT",
    see_also = {
      "CRITICAL",
      "ATOMIC",
      "omp_init_lock",
      "omp_lib",
    },
    signature = "HINT(hint-expression)",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Tell the implementation what kind of contention to expect on a synchronisation",
    valid_on = {
      "CRITICAL",
      "ATOMIC",
    },
  },
  ["if"] = {
    description = "On `PARALLEL`, a false condition means the region is executed by a team of ONE\n" ..
      "thread — the encountering thread — rather than being skipped; the construct still\n" ..
      "exists, so reductions and privatisation still happen, and `omp_in_parallel()`\n" ..
      "reports the region as inactive.\n" ..
      "\n" ..
      "On `TASK`, a false condition creates an UNDEFERRED task: the encountering thread\n" ..
      "executes it immediately and waits. On `TARGET`, a false condition runs the region\n" ..
      "on the host.\n" ..
      "\n" ..
      "Its everyday use is a work threshold: `IF(n > 10000)` avoids paying for team\n" ..
      "creation (a few microseconds — thousands of cycles) on small inputs, which is the\n" ..
      "difference between a speed-up and a slowdown for a routine called in an inner\n" ..
      "loop.\n" ..
      "\n" ..
      "When a combined construct could take the clause at more than one level, the\n" ..
      "directive-name modifier picks: `IF(PARALLEL: n > 1000)`, `IF(TARGET: use_gpu)`.",
    example = "!$omp parallel do if(n > 10000) default(none) shared(a, n) private(i)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "IF",
    see_also = {
      "NUM_THREADS",
      "FINAL",
      "TASK",
      "PARALLEL",
    },
    signature = "IF([directive-name-modifier:] scalar-logical-expr)",
    standard = "OpenMP 5.2",
    summary = "Apply the construct only when the condition is true",
    valid_on = {
      "PARALLEL",
      "TASK",
      "TASKLOOP",
      "TARGET",
      "SIMD",
      "CANCEL",
      "TARGET DATA",
    },
  },
  in_reduction = {
    description = "Written on a `TASK`, `TASKLOOP` or `TARGET` construct, it says the task\n" ..
      "contributes to the reduction declared by an enclosing `TASKGROUP` with\n" ..
      "`TASK_REDUCTION`, or by an enclosing `TASKLOOP` with `REDUCTION`.\n" ..
      "\n" ..
      "The operator and the variable must match the enclosing declaration exactly. A task\n" ..
      "that touches the reduction variable WITHOUT this clause is a data race, and it is\n" ..
      "not diagnosed.\n" ..
      "\n" ..
      "Together with `TASK_REDUCTION` this is how a recursive task decomposition\n" ..
      "accumulates a result without a critical region at every leaf.",
    example = "!$omp taskgroup task_reduction(+:total)\n" ..
      "!$omp task in_reduction(+:total)\n" ..
      "total = total + leaf_value()\n" ..
      "!$omp end task\n" ..
      "!$omp end taskgroup",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "IN_REDUCTION",
    see_also = {
      "TASK_REDUCTION",
      "REDUCTION",
      "TASKGROUP",
      "TASK",
    },
    signature = "IN_REDUCTION(operator : list)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Declare that this task participates in an enclosing task reduction",
    valid_on = {
      "TASK",
      "TASKLOOP",
      "TARGET",
    },
  },
  lastprivate = {
    description = "The variable is private during the construct; at the end, the value from the\n" ..
      "SEQUENTIALLY LAST iteration (or the lexically last `SECTION`) is copied into the\n" ..
      "original. 'Sequentially last' means the iteration that would have run last in the\n" ..
      "serial loop, not the one that finishes last in time.\n" ..
      "\n" ..
      "If that last iteration does not assign the variable, its value afterwards is\n" ..
      "undefined. The copy-out happens before the construct's implicit barrier.\n" ..
      "\n" ..
      "`LASTPRIVATE(CONDITIONAL: x)` (OpenMP 5.0) copies out the value from the last\n" ..
      "iteration that actually ASSIGNED the variable — the parallel equivalent of 'keep\n" ..
      "the last match found'.\n" ..
      "\n" ..
      "A variable may be both `FIRSTPRIVATE` and `LASTPRIVATE`, which gives copy-in and\n" ..
      "copy-out.",
    example = "!$omp parallel do lastprivate(last_good)\n" ..
      "do i = 1, n\n" ..
      "  if (ok(i)) last_good = i\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "LASTPRIVATE",
    see_also = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "REDUCTION",
    },
    signature = "LASTPRIVATE([CONDITIONAL:] list)",
    standard = "OpenMP 5.2 §5.4.5",
    summary = "Private copies whose sequentially-last value is copied back to the original",
    valid_on = {
      "DO",
      "SECTIONS",
      "SIMD",
      "TASKLOOP",
      "DISTRIBUTE",
    },
  },
  linear = {
    description = "`LINEAR(j:2)` says j is private, starts from its value before the loop, and in\n" ..
      "iteration i equals `j0 + i * 2`. The compiler can then compute it per lane instead\n" ..
      "of carrying a dependence, which is what allows an induction variable other than the\n" ..
      "loop index to appear in a vectorised loop.\n" ..
      "\n" ..
      "On `DECLARE SIMD` it marks an argument that advances linearly across the lanes of a\n" ..
      "call, so the vector version can take one value and a stride rather than a gather.\n" ..
      "\n" ..
      "At the end of the construct the original variable gets the value from the last\n" ..
      "iteration — like `LASTPRIVATE` with the arithmetic implied. Lying about the step is\n" ..
      "undefined behaviour with no diagnostic.",
    example = "!$omp simd linear(j:1)\n" ..
      "do i = 1, n\n" ..
      "  j = j + 1\n" ..
      "  b(j) = a(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "LINEAR",
    see_also = {
      "SIMD",
      "DECLARE SIMD",
      "PRIVATE",
      "LASTPRIVATE",
    },
    signature = "LINEAR(list[:linear-step])",
    standard = "OpenMP 5.2",
    summary = "Declare that a variable advances by a constant amount per iteration",
    valid_on = {
      "SIMD",
      "DO SIMD",
      "DECLARE SIMD",
      "DO",
    },
  },
  loop = {
    clauses = {
      "BIND",
      "ORDER",
      "COLLAPSE",
      "PRIVATE",
      "LASTPRIVATE",
      "REDUCTION",
    },
    description = "The DESCRIPTIVE loop construct: it asserts that the iterations may execute\n" ..
      "concurrently in any order and leaves the implementation free to choose how — which\n" ..
      "threads, which teams, which vector width. `DO`, by contrast, is PRESCRIPTIVE and\n" ..
      "pins down the mapping.\n" ..
      "\n" ..
      "`BIND(TEAMS|PARALLEL|THREAD)` says which level of parallelism the loop should be\n" ..
      "spread over; without it the binding comes from the enclosing region. `ORDER` is\n" ..
      "implicitly `CONCURRENT`.\n" ..
      "\n" ..
      "The restrictions that buy the freedom: the body may not contain most OpenMP\n" ..
      "constructs, may not call a procedure containing an orphaned worksharing\n" ..
      "construct, and must not depend on the iteration order. In return, one\n" ..
      "`!$OMP TARGET TEAMS LOOP` often matches a hand-tuned\n" ..
      "`TEAMS DISTRIBUTE PARALLEL DO SIMD` on a GPU while remaining readable — and it is\n" ..
      "the OpenMP counterpart of Fortran's `do concurrent`.",
    example = "!$omp target teams loop bind(teams)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "LOOP",
    see_also = {
      "DO",
      "DISTRIBUTE",
      "BIND",
      "ORDER",
      "concurrent",
    },
    signature = "!$OMP LOOP [clauses]",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Assert that the loop's iterations may run concurrently and let the implementation map them",
  },
  map = {
    description = "Map types: `TO` copies host to device on entry, `FROM` copies device to host on\n" ..
      "exit, `TOFROM` does both (the default for arrays), `ALLOC` reserves device storage\n" ..
      "with no copy, `RELEASE` decrements the reference count, `DELETE` removes the\n" ..
      "mapping outright.\n" ..
      "\n" ..
      "Getting these right is the whole performance story of offloading. `MAP(TO:)` for\n" ..
      "read-only inputs and `MAP(FROM:)` for outputs halves the traffic compared with the\n" ..
      "default `TOFROM`; `MAP(ALLOC:)` for scratch avoids copying uninitialised data in\n" ..
      "both directions.\n" ..
      "\n" ..
      "Array sections are supported — `map(to: a(1:n))` — and Fortran's descriptor makes\n" ..
      "assumed-shape arrays mappable, though non-contiguous sections may be copied\n" ..
      "element-wise or rejected depending on the compiler.\n" ..
      "\n" ..
      "Modifiers: `ALWAYS` forces the copy even if the data is already present,\n" ..
      "`CLOSE` asks for device-near memory, `PRESENT` (OpenMP 5.0) makes it an error if\n" ..
      "the data is not already mapped — a very useful assertion when a data region is\n" ..
      "supposed to have mapped it earlier.\n" ..
      "\n" ..
      "Mapping is reference-counted: nested `TARGET DATA` regions naming the same variable\n" ..
      "do not copy again, they increment the count.",
    example = "!$omp target map(to: a, b) map(from: c) map(alloc: scratch)\n" ..
      "c = a * b\n" ..
      "!$omp end target",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "MAP",
    see_also = {
      "TARGET",
      "TARGET DATA",
      "TARGET UPDATE",
      "DEVICE",
    },
    signature = "MAP([map-type-modifier,] map-type : list)",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Control how variables are moved between the host and a device data environment",
    valid_on = {
      "TARGET",
      "TARGET DATA",
      "TARGET ENTER DATA",
      "TARGET EXIT DATA",
      "DECLARE TARGET",
    },
  },
  masked = {
    clauses = {
      "FILTER",
    },
    description = "Without a clause the block is executed by the primary thread only — exactly what\n" ..
      "`MASTER` did. `FILTER(n)` selects the thread whose `omp_get_thread_num()` equals\n" ..
      "`n` instead; if no thread matches, the block is simply not executed.\n" ..
      "\n" ..
      "There is no implicit barrier at either end, so the other threads run straight on.\n" ..
      "Follow it with `!$OMP BARRIER` when they must not.\n" ..
      "\n" ..
      "Introduced in OpenMP 5.1 as the replacement for the deprecated `MASTER`.",
    example = "!$omp parallel\n" ..
      "!$omp masked filter(1)\n" ..
      "call log_progress(step)\n" ..
      "!$omp end masked\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "MASKED",
    see_also = {
      "MASTER",
      "SINGLE",
      "FILTER",
      "BARRIER",
    },
    signature = "!$OMP MASKED [FILTER(thread_num)]",
    standard = "OpenMP 5.2 (introduced in 5.1)",
    summary = "Execute the block only on the selected thread, with no barrier",
  },
  master = {
    clauses = {},
    description = "The block runs only on thread 0 of the current team; the other threads skip it\n" ..
      "and do NOT wait — there is no implicit barrier, which is the practical difference\n" ..
      "from `SINGLE`. Add an explicit `!$OMP BARRIER` if the rest of the team must not\n" ..
      "proceed until the block is done.\n" ..
      "\n" ..
      "**Deprecated in OpenMP 5.1** in favour of `MASKED`, which does the same thing with\n" ..
      "a `FILTER(thread_num)` clause that can name any thread and whose terminology is\n" ..
      "neutral. New code should use `MASKED`; existing `MASTER` constructs keep working.\n" ..
      "\n" ..
      "Note that `MASTER` is not a worksharing construct, so it may appear where `SINGLE`\n" ..
      "may not, and it does not participate in the 'no nesting of worksharing' rules.",
    example = "!$omp parallel\n" ..
      "!$omp master\n" ..
      "print *, 'threads:', omp_get_num_threads()\n" ..
      "!$omp end master\n" ..
      "!$omp barrier\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "MASTER",
    see_also = {
      "MASKED",
      "SINGLE",
      "BARRIER",
      "FILTER",
    },
    signature = "!$OMP MASTER",
    standard = "OpenMP 5.2",
    summary = "Deprecated: execute the block on the primary thread only, with no barrier",
  },
  mergeable = {
    description = "A hint that the task may be MERGED: if the implementation decides to execute it\n" ..
      "immediately (because it is undeferred or final), it may skip creating a separate\n" ..
      "data environment and run the body in the generating task's environment instead.\n" ..
      "\n" ..
      "That saves the firstprivate copies, which dominate the cost of a small task. It is\n" ..
      "only safe when the body does not depend on having its own copies — i.e. when\n" ..
      "running it as if it were inline would give the same answer.\n" ..
      "\n" ..
      "Usually paired with `FINAL`: at the bottom of a recursive decomposition, tasks stop\n" ..
      "being created and the remaining ones are final, undeferred and mergeable, which\n" ..
      "recovers serial performance in the leaves.",
    example = "!$omp task final(depth > 8) mergeable\n" ..
      "call solve(node, depth + 1)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "MERGEABLE",
    see_also = {
      "FINAL",
      "TASK",
      "IF",
      "UNTIED",
    },
    signature = "MERGEABLE",
    standard = "OpenMP 5.2",
    summary = "Permit an undeferred or included task to reuse the generating task's data environment",
    valid_on = {
      "TASK",
      "TASKLOOP",
    },
  },
  metadirective = {
    clauses = {
      "WHEN",
      "OTHERWISE",
      "DEFAULT",
    },
    description = "Selects which directive to apply at COMPILE time according to a context selector —\n" ..
      "the target device kind, the implementation vendor, the enclosing constructs, or a\n" ..
      "user condition. One source then carries a GPU variant and a CPU variant of the same\n" ..
      "loop without the preprocessor.\n" ..
      "\n" ..
      "`WHEN(device={arch(nvptx)}: target teams distribute parallel do)` and an\n" ..
      "`OTHERWISE(parallel do)` is the canonical pair. In OpenMP 5.2 the clause formerly\n" ..
      "spelled `DEFAULT` is renamed `OTHERWISE`; both are accepted in 5.2 and the old\n" ..
      "name is deprecated.\n" ..
      "\n" ..
      "Compiler support is uneven and the syntax is verbose; check that your compiler\n" ..
      "implements the selectors you rely on before building a code base around it.",
    example = "!$omp metadirective &\n" ..
      "!$omp   when(device={kind(gpu)}: target teams distribute parallel do) &\n" ..
      "!$omp   otherwise(parallel do)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "METADIRECTIVE",
    see_also = {
      "REQUIRES",
      "TARGET",
      "DECLARE TARGET",
    },
    signature = "!$OMP METADIRECTIVE WHEN(context-selector: directive) [OTHERWISE(directive)]",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Select which directive to apply according to a compile-time context selector",
  },
  nogroup = {
    description = "A `TASKLOOP` is normally wrapped in an implicit `TASKGROUP`, so control does not\n" ..
      "pass the construct until all its tasks have finished. `NOGROUP` removes that wait,\n" ..
      "letting the generating thread continue — useful when two independent taskloops\n" ..
      "should overlap, or when a later `TASKWAIT` or dependence will synchronise instead.\n" ..
      "\n" ..
      "With `NOGROUP` the results of the loop are NOT available after it. Anything that\n" ..
      "reads them needs `TASKWAIT`, an enclosing `TASKGROUP`, or a `DEPEND` chain.\n" ..
      "\n" ..
      "It is also incompatible with `REDUCTION` on the taskloop, whose combination happens\n" ..
      "at the implicit taskgroup's end.",
    example = "!$omp taskloop nogroup\n" ..
      "do i = 1, n\n" ..
      "  call work(i)\n" ..
      "end do\n" ..
      "!$omp taskwait",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "NOGROUP",
    see_also = {
      "TASKLOOP",
      "TASKGROUP",
      "TASKWAIT",
    },
    signature = "NOGROUP",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Remove the implicit taskgroup that makes a TASKLOOP wait for its tasks",
    valid_on = {
      "TASKLOOP",
    },
  },
  nowait = {
    description = "Worksharing constructs end with a barrier so that the next statement can rely on\n" ..
      "all the work being done. `NOWAIT` deletes that barrier, letting a thread that\n" ..
      "finishes early move straight on to the next construct. On an imbalanced loop\n" ..
      "followed by independent work that is free speed.\n" ..
      "\n" ..
      "It is safe only when nothing after the construct depends on what other threads\n" ..
      "wrote in it. Two successive `SCHEDULE(STATIC)` loops with identical bounds and\n" ..
      "chunk sizes are the one case the standard lets you rely on: thread k gets the same\n" ..
      "iterations in both, so a `NOWAIT` between them is legal even with a\n" ..
      "point-to-point dependence.\n" ..
      "\n" ..
      "In Fortran the clause goes on the END directive — `!$OMP END DO NOWAIT` — which is\n" ..
      "why `!$OMP END DO` stops being optional once you want it. It cannot be applied to\n" ..
      "`PARALLEL` or to any combined construct that ends a parallel region.\n" ..
      "\n" ..
      "On a `TARGET` construct `NOWAIT` means something different: it makes the offload an\n" ..
      "asynchronous target task, to be awaited with `TASKWAIT` or a `DEPEND` clause.",
    example = "!$omp do schedule(static)\n" ..
      "do i = 1, n\n" ..
      "  a(i) = f(i)\n" ..
      "end do\n" ..
      "!$omp end do nowait",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "NOWAIT",
    see_also = {
      "BARRIER",
      "DO",
      "SCHEDULE",
      "SINGLE",
      "TARGET",
    },
    signature = "NOWAIT",
    standard = "OpenMP 5.2",
    summary = "Remove the implicit barrier at the end of a worksharing construct",
    valid_on = {
      "DO",
      "SECTIONS",
      "SINGLE",
      "WORKSHARE",
      "TARGET",
      "TASKWAIT",
      "DO SIMD",
    },
  },
  num_tasks = {
    description = "The loop is split into `num-tasks` tasks (or fewer, if there are fewer iterations),\n" ..
      "each getting a roughly equal share. Use it when the number of workers is the\n" ..
      "natural unit — for instance a small multiple of `omp_get_num_threads()` to get\n" ..
      "load balance with a bounded task count.\n" ..
      "\n" ..
      "Mutually exclusive with `GRAINSIZE`. The `STRICT` modifier (OpenMP 5.1) makes the\n" ..
      "distribution exact rather than approximate.",
    example = "!$omp taskloop num_tasks(4 * omp_get_num_threads())\n" ..
      "do i = 1, n\n" ..
      "  call work(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "NUM_TASKS",
    see_also = {
      "GRAINSIZE",
      "TASKLOOP",
      "omp_get_num_threads",
    },
    signature = "NUM_TASKS([strict:] num-tasks)",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Request that the taskloop create exactly this many tasks",
    valid_on = {
      "TASKLOOP",
    },
  },
  num_teams = {
    description = "Bounds the number of teams created by a `TEAMS` construct; on a GPU this is\n" ..
      "effectively the grid size. OpenMP 5.1 allows a lower bound as well, so\n" ..
      "`NUM_TEAMS(64:256)` asks for a range.\n" ..
      "\n" ..
      "It is a request: the implementation may create fewer. With no clause the\n" ..
      "implementation chooses, and for a GPU that choice is usually good — tune it only\n" ..
      "with measurements, since too few teams underfills the device and too many adds\n" ..
      "scheduling overhead.\n" ..
      "\n" ..
      "`omp_get_num_teams()` reports the actual count inside the region and\n" ..
      "`omp_get_team_num()` identifies the team.",
    example = "!$omp target teams distribute parallel do num_teams(256) thread_limit(128)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "NUM_TEAMS",
    see_also = {
      "TEAMS",
      "THREAD_LIMIT",
      "DISTRIBUTE",
      "TARGET",
    },
    signature = "NUM_TEAMS([lower-bound:] upper-bound)",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Request how many teams the league should contain",
    valid_on = {
      "TEAMS",
      "TARGET TEAMS",
    },
  },
  num_threads = {
    description = "Overrides `omp_set_num_threads` and `OMP_NUM_THREADS` for this construct alone; it\n" ..
      "is a request, and the implementation may give fewer threads if dynamic adjustment\n" ..
      "is enabled (`omp_set_dynamic(.true.)`) or a thread limit is in force.\n" ..
      "\n" ..
      "It is the preferred way to fix a team size, because it is local and visible at the\n" ..
      "construct rather than being hidden in a call made elsewhere. Never call\n" ..
      "`omp_set_num_threads` from inside a parallel region to try to change the current\n" ..
      "team — the team size is fixed once the region starts.\n" ..
      "\n" ..
      "Asking for more threads than cores does not create parallelism; it creates\n" ..
      "oversubscription, which is disastrous when the region is inside an MPI rank that\n" ..
      "already has a core budget. In a hybrid MPI+OpenMP code, threads per rank times\n" ..
      "ranks per node should equal the cores per node.",
    example = "!$omp parallel num_threads(4) default(none) shared(work)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "NUM_THREADS",
    see_also = {
      "IF",
      "PROC_BIND",
      "omp_set_num_threads",
      "omp_get_num_threads",
    },
    signature = "NUM_THREADS(scalar-integer-expr)",
    standard = "OpenMP 5.2",
    summary = "Request a specific team size for this region only",
    valid_on = {
      "PARALLEL",
      "PARALLEL DO",
      "PARALLEL SECTIONS",
      "PARALLEL WORKSHARE",
      "TEAMS",
    },
  },
  omp_aligned_alloc = {
    interface = {
      {
        name = "alignment",
        type = "integer(c_size_t)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_aligned_alloc",
    result_type = "type(c_ptr)",
    signature = "omp_aligned_alloc(alignment, size, allocator)",
  },
  omp_aligned_calloc = {
    interface = {
      {
        name = "alignment",
        type = "integer(c_size_t)",
      },
      {
        name = "nmemb",
        type = "integer(c_size_t)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_aligned_calloc",
    result_type = "type(c_ptr)",
    signature = "omp_aligned_calloc(alignment, nmemb, size, allocator)",
  },
  omp_alloc = {
    interface = {
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_alloc",
    result_type = "type(c_ptr)",
    signature = "omp_alloc(size, allocator)",
  },
  omp_allocator_handle_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_allocator_handle_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "c_intptr_t",
  },
  omp_alloctrait = {
    kind = "type",
    module = "omp_lib",
    name = "omp_alloctrait",
    section = "omp_lib_kinds",
    signature = "type(omp_alloctrait)",
  },
  omp_alloctrait_key_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_alloctrait_key_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "c_int",
  },
  omp_alloctrait_val_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_alloctrait_val_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "c_intptr_t",
  },
  omp_atk_access = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_access",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "3",
  },
  omp_atk_alignment = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_alignment",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "2",
  },
  omp_atk_fallback = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_fallback",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "5",
  },
  omp_atk_fb_data = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_fb_data",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "6",
  },
  omp_atk_partition = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_partition",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "8",
  },
  omp_atk_pinned = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_pinned",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "7",
  },
  omp_atk_pool_size = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_pool_size",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "4",
  },
  omp_atk_sync_hint = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atk_sync_hint",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_key_kind)",
    value = "1",
  },
  omp_atv_abort_fb = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_abort_fb",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "13",
  },
  omp_atv_all = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_all",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "7",
  },
  omp_atv_allocator_fb = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_allocator_fb",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "14",
  },
  omp_atv_blocked = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_blocked",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "17",
  },
  omp_atv_cgroup = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_cgroup",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "10",
  },
  omp_atv_contended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_contended",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "3",
  },
  omp_atv_default = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_default",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "-1",
  },
  omp_atv_default_mem_fb = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_default_mem_fb",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "11",
  },
  omp_atv_environment = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_environment",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "15",
  },
  omp_atv_false = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_false",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "0",
  },
  omp_atv_interleaved = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_interleaved",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "18",
  },
  omp_atv_nearest = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_nearest",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "16",
  },
  omp_atv_null_fb = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_null_fb",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "12",
  },
  omp_atv_private = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_private",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "6",
  },
  omp_atv_pteam = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_pteam",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "9",
  },
  omp_atv_sequential = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_sequential",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "omp_atv_serialized",
  },
  omp_atv_serialized = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_serialized",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "5",
  },
  omp_atv_thread = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_thread",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "8",
  },
  omp_atv_true = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_true",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "1",
  },
  omp_atv_uncontended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_atv_uncontended",
    section = "omp_lib_kinds",
    type = "integer(omp_alloctrait_val_kind)",
    value = "4",
  },
  omp_calloc = {
    interface = {
      {
        name = "nmemb",
        type = "integer(c_size_t)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_calloc",
    result_type = "type(c_ptr)",
    signature = "omp_calloc(nmemb, size, allocator)",
  },
  omp_capture_affinity = {
    interface = {
      {
        intent = "out",
        name = "buffer",
        type = "character(len=*)",
      },
      {
        intent = "in",
        name = "format",
        type = "character(len=*)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_capture_affinity",
    result_type = "integer",
    signature = "omp_capture_affinity(buffer, format)",
  },
  omp_cgroup_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_cgroup_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "6",
  },
  omp_const_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_const_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "3",
  },
  omp_const_mem_space = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_const_mem_space",
    section = "omp_lib_kinds",
    type = "integer(omp_memspace_handle_kind)",
    value = "2",
  },
  omp_default_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_default_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "1",
  },
  omp_default_mem_space = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_default_mem_space",
    section = "omp_lib_kinds",
    type = "integer(omp_memspace_handle_kind)",
    value = "0",
  },
  omp_depend_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_depend_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "16",
  },
  omp_destroy_allocator = {
    interface = {
      {
        intent = "in",
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_destroy_allocator",
    signature = "omp_destroy_allocator(allocator)",
  },
  omp_destroy_lock = {
    description = "Uninitialises the lock. It must be unlocked and initialised when destroyed;\n" ..
      "destroying a lock another thread holds or is waiting on is undefined behaviour.\n" ..
      "\n" ..
      "After destruction the variable may be re-initialised with `omp_init_lock`. Destroy\n" ..
      "locks in serial code, symmetrically with their initialisation.",
    example = "call omp_destroy_lock(lck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_destroy_lock",
    params = {
      svar = "The lock variable to destroy; must be unlocked.",
    },
    result = "The lock's resources are released.",
    see_also = {
      "omp_init_lock",
      "omp_set_lock",
      "omp_destroy_nest_lock",
    },
    signature = "omp_destroy_lock(svar)",
    standard = "OpenMP 1.0",
    summary = "Release the resources of a simple lock variable",
  },
  omp_destroy_nest_lock = {
    description = "Uninitialises a nestable lock, which must be unlocked (nesting count zero) at the\n" ..
      "time. Destroying a held lock is undefined behaviour.\n" ..
      "\n" ..
      "Pair it with `omp_init_nest_lock` in serial code.",
    example = "call omp_destroy_nest_lock(nlck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_destroy_nest_lock",
    params = {
      nvar = "The nestable lock variable to destroy.",
    },
    result = "The lock's resources are released.",
    see_also = {
      "omp_init_nest_lock",
      "omp_unset_nest_lock",
      "omp_destroy_lock",
    },
    signature = "omp_destroy_nest_lock(nvar)",
    standard = "OpenMP 2.0",
    summary = "Release the resources of a nestable lock variable",
  },
  omp_display_affinity = {
    interface = {
      {
        intent = "in",
        name = "format",
        type = "character(len=*)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_display_affinity",
    signature = "omp_display_affinity(format)",
  },
  omp_display_env = {
    interface = {
      {
        intent = "in",
        name = "verbose",
        type = "logical",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_display_env",
    signature = "omp_display_env(verbose)",
  },
  omp_event_handle_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_event_handle_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "c_intptr_t",
  },
  omp_free = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_free",
    signature = "omp_free(ptr, allocator)",
  },
  omp_fulfill_event = {
    interface = {
      {
        intent = "in",
        name = "event",
        type = "integer(omp_event_handle_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_fulfill_event",
    signature = "omp_fulfill_event(event)",
  },
  omp_get_active_level = {
    description = "Counts only the enclosing parallel regions executed by a team of more than one\n" ..
      "thread. A region serialised by `IF(.false.)`, by `NUM_THREADS(1)`, or by the active\n" ..
      "level limit does not count.\n" ..
      "\n" ..
      "`omp_in_parallel()` is equivalent to `omp_get_active_level() > 0`.",
    example = "if (omp_get_active_level() > 0) call use_thread_safe_path()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_active_level",
    result = "The number of enclosing active parallel regions; 0 if none.",
    result_type = "integer",
    see_also = {
      "omp_get_level",
      "omp_in_parallel",
      "omp_get_max_active_levels",
    },
    signature = "omp_get_active_level()",
    standard = "OpenMP 3.0",
    summary = "Number of nested ACTIVE parallel regions enclosing the call",
  },
  omp_get_affinity_format = {
    interface = {
      {
        intent = "out",
        name = "buffer",
        type = "character(len=*)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_get_affinity_format",
    result_type = "integer",
    signature = "omp_get_affinity_format(buffer)",
  },
  omp_get_ancestor_thread_num = {
    description = "Given a level between 0 and `omp_get_level()`, returns the number the calling\n" ..
      "thread's ancestor had in the team at that level; level 0 always gives 0 and the\n" ..
      "current level gives `omp_get_thread_num()`. Out-of-range levels give -1.\n" ..
      "\n" ..
      "Together with `omp_get_team_size` it reconstructs the full position of a thread in\n" ..
      "a nested team hierarchy, which is the only way to build a globally unique thread\n" ..
      "identifier under nested parallelism.",
    example = "print *, 'ancestor at level 1:', omp_get_ancestor_thread_num(1)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "level",
        type = "integer",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_get_ancestor_thread_num",
    params = {
      level = "Nesting level to query, from 0 to omp_get_level().",
    },
    result = "The ancestor thread's number at that level, or -1 if the level is out of range.",
    result_type = "integer",
    see_also = {
      "omp_get_team_size",
      "omp_get_level",
      "omp_get_thread_num",
    },
    signature = "omp_get_ancestor_thread_num(level)",
    standard = "OpenMP 3.0",
    summary = "Thread number of this thread's ancestor at a given nesting level",
  },
  omp_get_cancellation = {
    description = "Returns the `cancel-var` ICV, which is set only by the `OMP_CANCELLATION`\n" ..
      "environment variable and cannot be changed at run time.\n" ..
      "\n" ..
      "When it is `.false.` every `CANCEL` and `CANCELLATION POINT` directive is a no-op —\n" ..
      "so a parallel search that 'does not stop early' almost always means this returns\n" ..
      "`.false.`. Check it at start-up and warn, rather than discovering it in a profile.",
    example = "if (.not. omp_get_cancellation()) then\n" ..
      "  print *, 'note: set OMP_CANCELLATION=true for early exit'\n" ..
      "end if",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_cancellation",
    result = "`.true.` if cancellation is enabled (`OMP_CANCELLATION=true`).",
    result_type = "logical",
    see_also = {
      "CANCEL",
      "CANCELLATION POINT",
    },
    signature = "omp_get_cancellation()",
    standard = "OpenMP 4.0",
    summary = "Test whether cancellation is enabled",
  },
  omp_get_default_allocator = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_default_allocator",
    signature = "omp_get_default_allocator()",
  },
  omp_get_default_device = {
    description = "Returns the `default-device-var` ICV — what a `TARGET` region without a `DEVICE`\n" ..
      "clause will use. The value comes from `omp_set_default_device` or\n" ..
      "`OMP_DEFAULT_DEVICE`.",
    example = "print *, 'default device:', omp_get_default_device()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_default_device",
    result = "The default device number for target regions.",
    result_type = "integer",
    see_also = {
      "omp_set_default_device",
      "DEVICE",
      "omp_get_num_devices",
    },
    signature = "omp_get_default_device()",
    standard = "OpenMP 4.0",
    summary = "Device number used by target regions with no DEVICE clause",
  },
  omp_get_device_num = {
    description = "Returns the number of the device executing the call — inside a `TARGET` region, the\n" ..
      "device it was offloaded to; on the host, the value of `omp_get_initial_device()`.\n" ..
      "\n" ..
      "It is the general form of `omp_is_initial_device()`, which only answers 'am I on\n" ..
      "the host'. Introduced in OpenMP 5.0.",
    example = "!$omp target\n" ..
      "print *, 'running on device', omp_get_device_num()\n" ..
      "!$omp end target",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_device_num",
    result = "The device number of the device executing the calling thread.",
    result_type = "integer",
    see_also = {
      "omp_is_initial_device",
      "omp_get_num_devices",
      "DEVICE",
    },
    signature = "omp_get_device_num()",
    standard = "OpenMP 5.0",
    summary = "Device number of the device the calling thread is executing on",
  },
  omp_get_dynamic = {
    description = "Returns the `dyn-var` ICV. If it is `.true.` the runtime may use fewer threads than\n" ..
      "requested for a parallel region, so `omp_get_max_threads()` becomes an upper bound\n" ..
      "rather than a promise.",
    example = "print *, 'dynamic threads:', omp_get_dynamic()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_dynamic",
    result = "`.true.` if dynamic adjustment of thread counts is enabled.",
    result_type = "logical",
    see_also = {
      "omp_set_dynamic",
      "omp_get_max_threads",
    },
    signature = "omp_get_dynamic()",
    standard = "OpenMP 1.0",
    summary = "Test whether dynamic thread adjustment is enabled",
  },
  omp_get_initial_device = {
    description = "Returns the device number that denotes the host. Passing it in a `DEVICE` clause\n" ..
      "targets the host explicitly, which is the portable way to force a `TARGET` region\n" ..
      "to run locally without deleting the directive.\n" ..
      "\n" ..
      "gfortran defines the constant `omp_initial_device = -1` in `omp_lib` for the same\n" ..
      "purpose.",
    example = "!$omp target device(omp_get_initial_device())",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_initial_device",
    result = "The device number of the initial (host) device.",
    result_type = "integer",
    see_also = {
      "omp_is_initial_device",
      "DEVICE",
      "omp_get_num_devices",
    },
    signature = "omp_get_initial_device()",
    standard = "OpenMP 4.0",
    summary = "Device number of the host device",
  },
  omp_get_level = {
    description = "Counts ALL enclosing parallel regions, whether they are active (more than one\n" ..
      "thread) or serialised. It is 0 in the sequential part of the program and 1 inside a\n" ..
      "top-level parallel region.\n" ..
      "\n" ..
      "Use it to detect that a library routine has been called from inside a parallel\n" ..
      "region at all; use `omp_get_active_level` when only regions with real parallelism\n" ..
      "matter.",
    example = "if (omp_get_level() == 0) call setup()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_level",
    result = "The nesting depth of parallel regions enclosing the call; 0 in serial code.",
    result_type = "integer",
    see_also = {
      "omp_get_active_level",
      "omp_in_parallel",
      "omp_get_ancestor_thread_num",
    },
    signature = "omp_get_level()",
    standard = "OpenMP 3.0",
    summary = "Number of nested parallel regions enclosing the call",
  },
  omp_get_mapped_ptr = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_get_mapped_ptr",
    result_type = "type(c_ptr)",
    signature = "omp_get_mapped_ptr(ptr, device_num)",
  },
  omp_get_max_active_levels = {
    description = "Returns the `max-active-levels-var` ICV — how deep active nesting may go, from\n" ..
      "`OMP_MAX_ACTIVE_LEVELS` or `omp_set_max_active_levels`. Regions deeper than this\n" ..
      "are executed by a team of one thread.",
    example = "print *, 'max active levels:', omp_get_max_active_levels()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_max_active_levels",
    result = "The maximum number of nested active parallel levels.",
    result_type = "integer",
    see_also = {
      "omp_set_max_active_levels",
      "omp_get_active_level",
      "omp_get_level",
    },
    signature = "omp_get_max_active_levels()",
    standard = "OpenMP 3.0",
    summary = "Maximum depth of nested ACTIVE parallel regions",
  },
  omp_get_max_task_priority = {
    description = "Returns the `max-task-priority-var` ICV, set by `OMP_MAX_TASK_PRIORITY`. **It is 0\n" ..
      "by default**, which means every `PRIORITY` clause is clamped to 0 and task\n" ..
      "priorities do nothing at all until the environment variable is set.\n" ..
      "\n" ..
      "Priorities are a hint even when enabled; use `DEPEND` for real ordering.",
    example = "print *, 'max task priority:', omp_get_max_task_priority()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_max_task_priority",
    result = "The largest priority value the implementation will honour; 0 by default.",
    result_type = "integer",
    see_also = {
      "PRIORITY",
      "TASK",
      "DEPEND",
    },
    signature = "omp_get_max_task_priority()",
    standard = "OpenMP 4.5",
    summary = "Maximum value accepted by the PRIORITY clause",
  },
  omp_get_max_teams = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_max_teams",
    result_type = "integer",
    signature = "omp_get_max_teams()",
  },
  omp_get_max_threads = {
    description = "Returns the value of the `nthreads-var` ICV — what the NEXT parallel region would\n" ..
      "ask for, not what the current one has. It is the right call for sizing per-thread\n" ..
      "arrays before entering a region, and it is valid in serial code.\n" ..
      "\n" ..
      "The actual team may still be smaller if dynamic adjustment is on.",
    example = "integer :: nt\n" ..
      "nt = 1\n" ..
      "!$ nt = omp_get_max_threads()\n" ..
      "allocate(partial(nt))",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_max_threads",
    result = "The number of threads the next parallel region would request.",
    result_type = "integer",
    see_also = {
      "omp_get_num_threads",
      "omp_set_num_threads",
      "omp_get_dynamic",
    },
    signature = "omp_get_max_threads()",
    standard = "OpenMP 1.0",
    summary = "Thread count a parallel region encountered now would request",
  },
  omp_get_nested = {
    description = "**Deprecated in OpenMP 5.0** along with `omp_set_nested`. It reports whether the\n" ..
      "maximum active-levels setting currently allows more than one level of active\n" ..
      "nesting; query `omp_get_max_active_levels()` instead, which gives the actual\n" ..
      "number.",
    example = "print *, 'max active levels:', omp_get_max_active_levels()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_nested",
    result = "`.true.` if nested parallelism is enabled (deprecated; prefer `omp_get_max_active_levels`).",
    result_type = "logical",
    see_also = {
      "omp_get_max_active_levels",
      "omp_set_nested",
      "omp_get_active_level",
    },
    signature = "omp_get_nested()",
    standard = "OpenMP 1.0 (deprecated in 5.0)",
    summary = "Deprecated: test whether nested parallelism is enabled",
  },
  omp_get_num_devices = {
    description = "Returns the number of non-host devices (GPUs, accelerators) the implementation can\n" ..
      "offload to. Zero means every `TARGET` region will run on the host — which is what a\n" ..
      "gfortran built without offload support reports, and the first thing to check when\n" ..
      "offloaded code runs at host speed.\n" ..
      "\n" ..
      "Device numbers run from 0 to this value minus 1;\n" ..
      "`omp_get_initial_device()` gives the host's number.",
    example = "if (omp_get_num_devices() > 0) then\n" ..
      "  call omp_set_default_device(mod(rank, omp_get_num_devices()))\n" ..
      "end if",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_num_devices",
    result = "The number of target devices; 0 if none are available.",
    result_type = "integer",
    see_also = {
      "DEVICE",
      "omp_get_device_num",
      "omp_is_initial_device",
      "TARGET",
    },
    signature = "omp_get_num_devices()",
    standard = "OpenMP 4.0",
    summary = "Number of target devices available",
  },
  omp_get_num_places = {
    description = "Returns the number of PLACES defined by `OMP_PLACES` — the units threads may be\n" ..
      "bound to, such as `cores`, `threads` (hardware threads) or `sockets`. Zero means no\n" ..
      "place list is defined, so binding cannot do anything.\n" ..
      "\n" ..
      "With `omp_get_place_num_procs` and `omp_get_place_proc_ids` it lets a program print\n" ..
      "the machine topology it was actually given, which is usually more informative than\n" ..
      "what the batch script intended.",
    example = "print *, 'places:', omp_get_num_places()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_num_places",
    result = "The number of places available to the program.",
    result_type = "integer",
    see_also = {
      "PROC_BIND",
      "omp_get_proc_bind",
      "omp_get_num_procs",
    },
    signature = "omp_get_num_places()",
    standard = "OpenMP 4.5",
    summary = "Number of places in the place list",
  },
  omp_get_num_procs = {
    description = "Returns the number of processing units the implementation believes are available —\n" ..
      "on Linux with gfortran, the size of the process's CPU affinity mask, so it reflects\n" ..
      "`taskset`, cgroups and most batch-system pinning.\n" ..
      "\n" ..
      "It is NOT the right default for the thread count in a hybrid MPI+OpenMP job: every\n" ..
      "rank on a node sees the same processors unless the launcher pinned them, so using\n" ..
      "it per rank oversubscribes the node by the number of ranks. Take the thread count\n" ..
      "from the batch system instead.",
    example = "print *, 'cores visible:', omp_get_num_procs()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_num_procs",
    result = "The number of processors available to the program.",
    result_type = "integer",
    see_also = {
      "omp_get_max_threads",
      "omp_get_num_places",
      "PROC_BIND",
    },
    signature = "omp_get_num_procs()",
    standard = "OpenMP 1.0",
    summary = "Number of processors available to the program",
  },
  omp_get_num_teams = {
    description = "Returns the number of teams created by the enclosing `TEAMS` construct, or 1\n" ..
      "outside one. Together with `omp_get_team_num` it gives a team its coordinates\n" ..
      "inside the league, which is how a GPU kernel partitions work when\n" ..
      "`DISTRIBUTE` is not used.",
    example = "!$omp target teams\n" ..
      "print *, omp_get_team_num(), 'of', omp_get_num_teams()\n" ..
      "!$omp end target teams",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_num_teams",
    result = "The number of teams in the current league; 1 outside a teams region.",
    result_type = "integer",
    see_also = {
      "TEAMS",
      "NUM_TEAMS",
      "DISTRIBUTE",
    },
    signature = "omp_get_num_teams()",
    standard = "OpenMP 4.0",
    summary = "Number of teams in the current league",
  },
  omp_get_num_threads = {
    description = "Returns the size of the CURRENT team. Called from serial code — or from any region\n" ..
      "that is not active — it returns 1, which is the single most common surprise: a call\n" ..
      "before the `!$OMP PARALLEL` does not tell you how many threads you are about to\n" ..
      "get. That is `omp_get_max_threads()`.",
    example = "!$omp parallel\n" ..
      "!$omp single\n" ..
      "print *, 'team size:', omp_get_num_threads()\n" ..
      "!$omp end single\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_num_threads",
    result = "The number of threads in the current team; 1 outside any active parallel region.",
    result_type = "integer",
    see_also = {
      "omp_get_max_threads",
      "omp_get_thread_num",
      "NUM_THREADS",
    },
    signature = "omp_get_num_threads()",
    standard = "OpenMP 1.0",
    summary = "Number of threads in the team executing the current region",
  },
  omp_get_partition_num_places = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_partition_num_places",
    result_type = "integer",
    signature = "omp_get_partition_num_places()",
  },
  omp_get_partition_place_nums = {
    interface = {
      {
        dim = "(*)",
        intent = "out",
        name = "place_nums",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_get_partition_place_nums",
    signature = "omp_get_partition_place_nums(place_nums)",
  },
  omp_get_place_num = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_place_num",
    result_type = "integer",
    signature = "omp_get_place_num()",
  },
  omp_get_place_num_procs = {
    interface = {
      {
        intent = "in",
        name = "place_num",
        type = "integer",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_get_place_num_procs",
    result_type = "integer",
    signature = "omp_get_place_num_procs(place_num)",
  },
  omp_get_place_proc_ids = {
    interface = {
      {
        intent = "in",
        name = "place_num",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "out",
        name = "ids",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_get_place_proc_ids",
    signature = "omp_get_place_proc_ids(place_num, ids)",
  },
  omp_get_proc_bind = {
    description = "Returns an `omp_proc_bind_kind` value from `omp_lib_kinds`:\n" ..
      "`omp_proc_bind_false` (binding off), `omp_proc_bind_true`,\n" ..
      "`omp_proc_bind_primary` (spelled `omp_proc_bind_master` before OpenMP 5.1, and\n" ..
      "still defined), `omp_proc_bind_close` or `omp_proc_bind_spread`.\n" ..
      "\n" ..
      "It reports the value the next parallel region would use, from `OMP_PROC_BIND` or\n" ..
      "the enclosing `PROC_BIND` clause. Printing it at start-up is the quickest way to\n" ..
      "confirm that a batch script's affinity settings actually reached the program.",
    example = "!$ use omp_lib\n" ..
      "if (omp_get_proc_bind() == omp_proc_bind_false) print *, 'warning: threads unbound'",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_proc_bind",
    result = "One of the `omp_proc_bind_*` constants describing the binding policy in effect.",
    result_type = "integer(omp_proc_bind_kind)",
    see_also = {
      "PROC_BIND",
      "omp_get_num_places",
      "omp_lib_kinds",
    },
    signature = "omp_get_proc_bind()",
    standard = "OpenMP 4.0",
    summary = "Thread affinity policy in force for the current region",
  },
  omp_get_schedule = {
    description = "A SUBROUTINE with two output arguments, not a function: the first receives the\n" ..
      "`omp_sched_kind` value and the second the chunk size. A returned chunk size of 0 or\n" ..
      "less means the implementation default is in force.\n" ..
      "\n" ..
      "The values come from `omp_set_schedule` or, failing that, the `OMP_SCHEDULE`\n" ..
      "environment variable. Useful for reporting the configuration of a run in a log\n" ..
      "alongside the thread count.",
    example = "!$ use omp_lib\n" ..
      "integer(omp_sched_kind) :: kind\n" ..
      "integer :: chunk\n" ..
      "!$ call omp_get_schedule(kind, chunk)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "out",
        name = "kind",
        type = "integer(omp_sched_kind)",
      },
      {
        intent = "out",
        name = "chunk_size",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_get_schedule",
    params = {
      chunk_size = "Returns the chunk size.",
      kind = "Returns the schedule kind.",
    },
    result = "**kind** and **chunk_size** describe the current runtime schedule.",
    see_also = {
      "omp_set_schedule",
      "SCHEDULE",
      "omp_lib_kinds",
    },
    signature = "omp_get_schedule(kind, chunk_size)",
    standard = "OpenMP 3.0",
    summary = "Retrieve the schedule that SCHEDULE(RUNTIME) loops will use",
  },
  omp_get_supported_active_levels = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_supported_active_levels",
    result_type = "integer",
    signature = "omp_get_supported_active_levels()",
  },
  omp_get_team_num = {
    description = "Returns a number in `0 .. omp_get_num_teams()-1`, or 0 outside a `TEAMS` region.\n" ..
      "Teams cannot synchronise with each other, so this identifies a partition of work,\n" ..
      "not a participant in a protocol.",
    example = "!$omp target teams\n" ..
      "call work_on_partition(omp_get_team_num())\n" ..
      "!$omp end target teams",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_team_num",
    result = "The calling team's number in the league; 0 outside a teams region.",
    result_type = "integer",
    see_also = {
      "TEAMS",
      "omp_get_num_teams",
      "DISTRIBUTE",
    },
    signature = "omp_get_team_num()",
    standard = "OpenMP 4.0",
    summary = "Team number of the calling thread's team within the league",
  },
  omp_get_team_size = {
    description = "Returns the number of threads in the team the calling thread's ancestor belonged to\n" ..
      "at the given level; level 0 gives 1 and the current level gives\n" ..
      "`omp_get_num_threads()`. An out-of-range level gives -1.\n" ..
      "\n" ..
      "The pair `(omp_get_ancestor_thread_num(l), omp_get_team_size(l))` describes the\n" ..
      "thread's position at every level of a nested hierarchy.",
    example = "do l = 0, omp_get_level()\n" ..
      "  print *, l, omp_get_ancestor_thread_num(l), omp_get_team_size(l)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "level",
        type = "integer",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_get_team_size",
    params = {
      level = "Nesting level to query, from 0 to omp_get_level().",
    },
    result = "The team size at that nesting level, or -1 if the level is out of range.",
    result_type = "integer",
    see_also = {
      "omp_get_ancestor_thread_num",
      "omp_get_level",
      "omp_get_num_threads",
    },
    signature = "omp_get_team_size(level)",
    standard = "OpenMP 3.0",
    summary = "Size of the thread team at a given nesting level",
  },
  omp_get_teams_thread_limit = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_teams_thread_limit",
    result_type = "integer",
    signature = "omp_get_teams_thread_limit()",
  },
  omp_get_thread_limit = {
    description = "Returns the `thread-limit-var` ICV: the ceiling on the total number of threads the\n" ..
      "program may use, set by `OMP_THREAD_LIMIT` or by a `THREAD_LIMIT` clause on an\n" ..
      "enclosing construct.\n" ..
      "\n" ..
      "It bounds nested parallelism in particular: an inner region cannot push the total\n" ..
      "past this limit, however many threads its `NUM_THREADS` asks for.",
    example = "print *, 'thread limit:', omp_get_thread_limit()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_thread_limit",
    result = "The maximum number of threads available to the program.",
    result_type = "integer",
    see_also = {
      "THREAD_LIMIT",
      "omp_get_max_active_levels",
      "omp_get_max_threads",
    },
    signature = "omp_get_thread_limit()",
    standard = "OpenMP 3.0",
    summary = "Maximum number of OpenMP threads available to the whole program",
  },
  omp_get_thread_num = {
    description = "Returns 0 for the primary thread and up to `omp_get_num_threads()-1` for the\n" ..
      "others; 0 in serial code. The number identifies a thread only within the CURRENT\n" ..
      "team, so it is not a global identity and it is not stable across regions.\n" ..
      "\n" ..
      "Do not use it to divide work by hand — that is what the worksharing constructs do,\n" ..
      "correctly and with a schedule. Use it for per-thread diagnostics, and for indexing\n" ..
      "a per-thread array whose length is `omp_get_max_threads()`.\n" ..
      "\n" ..
      "In an `UNTIED` task the value may change after a suspension point.",
    example = "!$omp parallel private(tid)\n" ..
      "tid = 0\n" ..
      "!$ tid = omp_get_thread_num()\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_thread_num",
    result = "The calling thread's number in its team, 0 for the primary thread.",
    result_type = "integer",
    see_also = {
      "omp_get_num_threads",
      "MASKED",
      "omp_get_ancestor_thread_num",
    },
    signature = "omp_get_thread_num()",
    standard = "OpenMP 1.0",
    summary = "Calling thread's number within its team",
  },
  omp_get_wtick = {
    description = "Returns the number of seconds between two successive ticks of the timer used by\n" ..
      "`omp_get_wtime` — the smallest interval that can be resolved. On Linux it is\n" ..
      "typically of the order of a nanosecond.\n" ..
      "\n" ..
      "Use it to decide whether a measured interval is meaningful: timing a region that\n" ..
      "lasts a handful of ticks measures the clock, not the code. Repeat the region until\n" ..
      "the elapsed time is several orders of magnitude larger than the tick.",
    example = "print *, 'timer resolution (s):', omp_get_wtick()",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_wtick",
    result = "Seconds between successive clock ticks, as DOUBLE PRECISION.",
    result_type = "double precision",
    see_also = {
      "omp_get_wtime",
      "MPI_Wtick",
      "system_clock",
    },
    signature = "omp_get_wtick()",
    standard = "OpenMP 2.0",
    summary = "Resolution of the omp_get_wtime clock, in seconds",
  },
  omp_get_wtime = {
    description = "The natural timer for an OpenMP program: it measures WALL-CLOCK time, not CPU time,\n" ..
      "so it reports what a parallel region actually saved, whereas `cpu_time` sums over\n" ..
      "all threads and appears to get worse as you add them.\n" ..
      "\n" ..
      "Take the difference of two calls on the same thread; the origin is arbitrary and\n" ..
      "only guaranteed to be fixed for the life of the program. Wrap timed regions in a\n" ..
      "barrier when timing a parallel construct, so that the measurement is not taken\n" ..
      "while other threads are still working.",
    example = "double precision :: t0, t1\n" ..
      "t0 = omp_get_wtime()\n" ..
      "call solve()\n" ..
      "t1 = omp_get_wtime()\n" ..
      "print '(a,f8.3)', 'seconds: ', t1 - t0",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_get_wtime",
    result = "Wall-clock seconds as DOUBLE PRECISION from an arbitrary origin; only *differences* of two calls on the **same thread** are meaningful.",
    result_type = "double precision",
    see_also = {
      "omp_get_wtick",
      "MPI_Wtime",
      "system_clock",
    },
    signature = "omp_get_wtime()",
    standard = "OpenMP 2.0",
    summary = "Elapsed wall-clock time in seconds",
  },
  omp_high_bw_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_high_bw_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "4",
  },
  omp_high_bw_mem_space = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_high_bw_mem_space",
    section = "omp_lib_kinds",
    type = "integer(omp_memspace_handle_kind)",
    value = "3",
  },
  omp_in_explicit_task = {
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_in_explicit_task",
    result_type = "logical",
    signature = "omp_in_explicit_task()",
  },
  omp_in_final = {
    description = "Returns `.true.` when the calling task is final — because a `FINAL` clause was true\n" ..
      "or because an ancestor task was final. Every task generated from a final task is\n" ..
      "itself final and undeferred.\n" ..
      "\n" ..
      "The point is to skip the task-generating code entirely at the bottom of a recursion\n" ..
      "rather than creating tasks that will be executed immediately anyway; the saving is\n" ..
      "the whole task construction cost.",
    example = "if (omp_in_final()) then\n" ..
      "  call solve_serial(node)\n" ..
      "else\n" ..
      "  !$omp task\n" ..
      "  call solve(node)\n" ..
      "  !$omp end task\n" ..
      "end if",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_in_final",
    result = "`.true.` if the calling task is a final task.",
    result_type = "logical",
    see_also = {
      "FINAL",
      "MERGEABLE",
      "TASK",
    },
    signature = "omp_in_final()",
    standard = "OpenMP 3.1",
    summary = "Test whether the calling task is a final task",
  },
  omp_in_parallel = {
    description = "Returns `.true.` if the enclosing region is an active parallel region — one\n" ..
      "executed by a team of more than one thread. A region serialised by `IF(.false.)` or\n" ..
      "by a team of one is INACTIVE and gives `.false.`.\n" ..
      "\n" ..
      "The usual use is a library routine that must behave differently when called from\n" ..
      "inside a parallel region (for example, not opening one of its own).",
    example = "if (omp_in_parallel()) then\n" ..
      "  call serial_kernel()\n" ..
      "else\n" ..
      "  call parallel_kernel()\n" ..
      "end if",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_in_parallel",
    result = "`.true.` inside an active parallel region, `.false.` otherwise.",
    result_type = "logical",
    see_also = {
      "omp_get_level",
      "omp_get_active_level",
      "IF",
    },
    signature = "omp_in_parallel()",
    standard = "OpenMP 1.0",
    summary = "Test whether the call is inside an ACTIVE parallel region",
  },
  omp_init_allocator = {
    interface = {
      {
        intent = "in",
        name = "memspace",
        type = "integer(omp_memspace_handle_kind)",
      },
      {
        intent = "in",
        name = "ntraits",
        type = "integer",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "traits",
        type = "type(omp_alloctrait)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_init_allocator",
    signature = "omp_init_allocator(memspace, ntraits, traits)",
  },
  omp_init_lock = {
    description = "The argument is `integer(omp_lock_kind)` from `omp_lib_kinds` and is OPAQUE — never\n" ..
      "copy it, compare it, or pass it by value. Every lock must be initialised exactly\n" ..
      "once before any thread uses it, and initialising a lock that is already initialised\n" ..
      "is undefined behaviour.\n" ..
      "\n" ..
      "Locks give what `CRITICAL` cannot: a lock per object rather than per code region,\n" ..
      "so a hash table with 64 buckets can have 64 locks and threads working on different\n" ..
      "buckets never contend. The cost is that the discipline is now yours — an\n" ..
      "unbalanced set/unset deadlocks, and a lock held across a barrier deadlocks the\n" ..
      "team.\n" ..
      "\n" ..
      "Initialise in serial code or inside a `SINGLE` region; the lock variable itself\n" ..
      "must be shared by the threads that use it.",
    example = "!$ use omp_lib\n" ..
      "integer(omp_lock_kind) :: lck\n" ..
      "call omp_init_lock(lck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "out",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_init_lock",
    params = {
      svar = "The lock variable, declared `integer(kind=omp_lock_kind)`.",
    },
    result = "The lock is initialized and unlocked.",
    see_also = {
      "omp_destroy_lock",
      "omp_set_lock",
      "omp_unset_lock",
      "omp_test_lock",
      "CRITICAL",
    },
    signature = "omp_init_lock(svar)",
    standard = "OpenMP 1.0",
    summary = "Initialise a simple lock variable and leave it unlocked",
  },
  omp_init_lock_with_hint = {
    interface = {
      {
        intent = "out",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
      {
        intent = "in",
        name = "hint",
        type = "integer(omp_lock_hint_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_init_lock_with_hint",
    signature = "omp_init_lock_with_hint(svar, hint)",
  },
  omp_init_nest_lock = {
    description = "The argument is `integer(omp_nest_lock_kind)` — a different kind from a simple\n" ..
      "lock, and the two families of routines may not be mixed on the same variable.\n" ..
      "\n" ..
      "A nestable lock keeps a NESTING COUNT: the owning thread may set it repeatedly\n" ..
      "without deadlocking, and must unset it the same number of times before another\n" ..
      "thread can take it. That is what makes recursive code, or a routine that may be\n" ..
      "called both from inside and outside a locked region, safe.\n" ..
      "\n" ..
      "The cost is a slightly more expensive lock; prefer a simple lock when recursion is\n" ..
      "not possible.",
    example = "!$ use omp_lib\n" ..
      "integer(omp_nest_lock_kind) :: nlck\n" ..
      "call omp_init_nest_lock(nlck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "out",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_init_nest_lock",
    params = {
      nvar = "The lock variable, declared `integer(kind=omp_nest_lock_kind)`.",
    },
    result = "The nestable lock is initialized and unlocked.",
    see_also = {
      "omp_set_nest_lock",
      "omp_unset_nest_lock",
      "omp_destroy_nest_lock",
      "omp_init_lock",
    },
    signature = "omp_init_nest_lock(nvar)",
    standard = "OpenMP 2.0",
    summary = "Initialise a nestable lock variable and leave it unlocked",
  },
  omp_init_nest_lock_with_hint = {
    interface = {
      {
        intent = "out",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
      {
        intent = "in",
        name = "hint",
        type = "integer(omp_lock_hint_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_init_nest_lock_with_hint",
    signature = "omp_init_nest_lock_with_hint(nvar, hint)",
  },
  omp_initial_device = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_initial_device",
    section = "omp_lib_kinds",
    type = "integer",
    value = "-1",
  },
  omp_invalid_device = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_invalid_device",
    section = "omp_lib_kinds",
    type = "integer",
    value = "-4",
  },
  omp_is_initial_device = {
    description = "Returns `.true.` when the calling code is executing on the initial (host) device\n" ..
      "and `.false.` inside a `TARGET` region running on an accelerator.\n" ..
      "\n" ..
      "Its main use is inside a target region, to take a different code path — or to\n" ..
      "report loudly — when the region fell back to the host because no device was\n" ..
      "available or an `IF` clause was false.",
    example = "!$omp target\n" ..
      "if (omp_is_initial_device()) print *, 'fell back to the host'\n" ..
      "!$omp end target",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {},
    kind = "function",
    module = "omp_lib",
    name = "omp_is_initial_device",
    result = "`.true.` if executing on the host device, `.false.` on a target device.",
    result_type = "logical",
    see_also = {
      "omp_get_device_num",
      "omp_get_num_devices",
      "TARGET",
    },
    signature = "omp_is_initial_device()",
    standard = "OpenMP 4.0",
    summary = "Test whether the code is running on the host device",
  },
  omp_large_cap_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_large_cap_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "2",
  },
  omp_large_cap_mem_space = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_large_cap_mem_space",
    section = "omp_lib_kinds",
    type = "integer(omp_memspace_handle_kind)",
    value = "1",
  },
  omp_lib = {
    description = "`omp_lib` declares every OpenMP runtime routine (`omp_get_thread_num`,\n" ..
      "`omp_get_wtime`, the lock routines, the device routines) with an explicit\n" ..
      "interface, plus the kind and enumeration constants of `omp_lib_kinds`. gfortran\n" ..
      "provides it as a module and as the older `include 'omp_lib.h'` header; the module\n" ..
      "is the one to use, because it gets argument checking.\n" ..
      "\n" ..
      "**Write it as `!$ use omp_lib`.** The `!$` sentinel is OpenMP CONDITIONAL\n" ..
      "COMPILATION: with `-fopenmp` the compiler replaces `!$` with two spaces and the\n" ..
      "line becomes a real `use` statement; without `-fopenmp` it stays a comment and the\n" ..
      "program still compiles, without needing the module to exist at all.\n" ..
      "\n" ..
      "That matters because of the fact underneath all of this: **without `-fopenmp`\n" ..
      "every `!$OMP` directive in the file is just a comment.** The code compiles\n" ..
      "cleanly, runs correctly, and runs on ONE thread — no warning, no error, no hint\n" ..
      "that the parallelism you wrote was discarded. A program that calls\n" ..
      "`omp_get_max_threads()` unconditionally will not even link without the flag, which\n" ..
      "is one way to notice; the conditional `!$` form deliberately removes that warning,\n" ..
      "so guard the calls too, or give them a serial fallback:\n" ..
      "\n" ..
      "```fortran\n" ..
      "integer :: nthreads\n" ..
      "nthreads = 1\n" ..
      "!$ nthreads = omp_get_max_threads()\n" ..
      "```\n" ..
      "\n" ..
      "Link and compile with `-fopenmp` (gfortran) or `-qopenmp` / `-fiopenmp` (Intel);\n" ..
      "the flag is needed at BOTH compile and link time, and omitting it at link gives\n" ..
      "undefined references to `GOMP_parallel`.",
    example = "program main\n" ..
      "  !$ use omp_lib\n" ..
      "  implicit none\n" ..
      "  integer :: tid, nthreads\n" ..
      "  nthreads = 1\n" ..
      "  !$ nthreads = omp_get_max_threads()\n" ..
      "  print *, 'threads available:', nthreads\n" ..
      "end program",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "module",
    module = "OpenMP 5.2",
    name = "omp_lib",
    see_also = {
      "omp_lib_kinds",
      "omp_get_thread_num",
      "omp_get_wtime",
      "PARALLEL",
    },
    signature = "use omp_lib",
    standard = "OpenMP 2.0",
    summary = "The OpenMP Fortran runtime library module",
  },
  omp_lib_kinds = {
    description = "Defines the kinds of the opaque types the runtime routines take: `omp_lock_kind`\n" ..
      "and `omp_nest_lock_kind` (lock variables), `omp_sched_kind` (the `omp_sched_static`,\n" ..
      "`omp_sched_dynamic`, `omp_sched_guided`, `omp_sched_auto` constants),\n" ..
      "`omp_proc_bind_kind` (`omp_proc_bind_false/true/primary/master/close/spread`),\n" ..
      "`omp_sync_hint_kind` (with `omp_lock_hint_kind` as its deprecated synonym),\n" ..
      "`omp_depend_kind`, `omp_event_handle_kind`, `omp_allocator_handle_kind`,\n" ..
      "`omp_memspace_handle_kind` and `omp_pause_resource_kind`.\n" ..
      "\n" ..
      "`use omp_lib` re-exports all of it, so a separate `use omp_lib_kinds` is rarely\n" ..
      "needed — but declaring a lock with the right kind is not optional:\n" ..
      "`integer(omp_lock_kind) :: lck` is the only portable spelling, since the value of\n" ..
      "the kind differs between implementations (gfortran uses 4 for a simple lock and 8\n" ..
      "for a nestable one).\n" ..
      "\n" ..
      "The constants are ordinary Fortran named constants, so they may be used in `select\n" ..
      "case` and compared directly, for example against the result of\n" ..
      "`omp_get_proc_bind()`.",
    example = "!$ use omp_lib\n" ..
      "integer(omp_lock_kind) :: lck\n" ..
      "integer(omp_sched_kind) :: sched\n" ..
      "integer :: chunk\n" ..
      "call omp_get_schedule(sched, chunk)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "module",
    module = "OpenMP 5.2",
    name = "omp_lib_kinds",
    see_also = {
      "omp_lib",
      "omp_init_lock",
      "omp_get_schedule",
      "omp_get_proc_bind",
    },
    signature = "use omp_lib_kinds",
    standard = "OpenMP 2.0",
    summary = "Kind parameters and enumeration constants for the OpenMP runtime types",
  },
  omp_lock_hint_contended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_contended",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "omp_sync_hint_contended",
  },
  omp_lock_hint_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "omp_sync_hint_kind",
  },
  omp_lock_hint_none = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_none",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "omp_sync_hint_none",
  },
  omp_lock_hint_nonspeculative = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_nonspeculative",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "omp_sync_hint_nonspeculative",
  },
  omp_lock_hint_speculative = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_speculative",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "omp_sync_hint_speculative",
  },
  omp_lock_hint_uncontended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_hint_uncontended",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "omp_sync_hint_uncontended",
  },
  omp_lock_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_lock_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "4",
  },
  omp_low_lat_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_low_lat_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "5",
  },
  omp_low_lat_mem_space = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_low_lat_mem_space",
    section = "omp_lib_kinds",
    type = "integer(omp_memspace_handle_kind)",
    value = "4",
  },
  omp_memspace_handle_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_memspace_handle_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "c_intptr_t",
  },
  omp_nest_lock_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_nest_lock_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "8",
  },
  omp_null_allocator = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_null_allocator",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "0",
  },
  omp_pause_hard = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_pause_hard",
    section = "omp_lib_kinds",
    type = "integer(omp_pause_resource_kind)",
    value = "2",
  },
  omp_pause_resource = {
    interface = {
      {
        intent = "in",
        name = "kind",
        type = "integer(omp_pause_resource_kind)",
      },
      {
        name = "device_num",
        type = "integer",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_pause_resource",
    result_type = "integer",
    signature = "omp_pause_resource(kind, device_num)",
  },
  omp_pause_resource_all = {
    interface = {
      {
        intent = "in",
        name = "kind",
        type = "integer(omp_pause_resource_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_pause_resource_all",
    result_type = "integer",
    signature = "omp_pause_resource_all(kind)",
  },
  omp_pause_resource_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_pause_resource_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "4",
  },
  omp_pause_soft = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_pause_soft",
    section = "omp_lib_kinds",
    type = "integer(omp_pause_resource_kind)",
    value = "1",
  },
  omp_proc_bind_close = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_close",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "3",
  },
  omp_proc_bind_false = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_false",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "0",
  },
  omp_proc_bind_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "4",
  },
  omp_proc_bind_master = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_master",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "2",
  },
  omp_proc_bind_primary = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_primary",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "2",
  },
  omp_proc_bind_spread = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_spread",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "4",
  },
  omp_proc_bind_true = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_proc_bind_true",
    section = "omp_lib_kinds",
    type = "integer(omp_proc_bind_kind)",
    value = "1",
  },
  omp_pteam_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_pteam_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "7",
  },
  omp_realloc = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
      {
        name = "free_allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_realloc",
    result_type = "type(c_ptr)",
    signature = "omp_realloc(ptr, size, allocator, free_allocator)",
  },
  omp_sched_auto = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sched_auto",
    section = "omp_lib_kinds",
    type = "integer(omp_sched_kind)",
    value = "4",
  },
  omp_sched_dynamic = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sched_dynamic",
    section = "omp_lib_kinds",
    type = "integer(omp_sched_kind)",
    value = "2",
  },
  omp_sched_guided = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sched_guided",
    section = "omp_lib_kinds",
    type = "integer(omp_sched_kind)",
    value = "3",
  },
  omp_sched_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sched_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "4",
  },
  omp_sched_static = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sched_static",
    section = "omp_lib_kinds",
    type = "integer(omp_sched_kind)",
    value = "1",
  },
  omp_set_affinity_format = {
    interface = {
      {
        intent = "in",
        name = "format",
        type = "character(len=*)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_affinity_format",
    signature = "omp_set_affinity_format(format)",
  },
  omp_set_default_allocator = {
    interface = {
      {
        intent = "in",
        name = "allocator",
        type = "integer(omp_allocator_handle_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_default_allocator",
    signature = "omp_set_default_allocator(allocator)",
  },
  omp_set_default_device = {
    description = "Sets the `default-device-var` ICV for the calling thread, overriding\n" ..
      "`OMP_DEFAULT_DEVICE`. In a multi-GPU run the usual idiom is one call per MPI rank\n" ..
      "at start-up, mapping rank to device.\n" ..
      "\n" ..
      "Setting it does not move data: mappings belong to the device they were made on, so\n" ..
      "change the default device before any `TARGET DATA` region, not in the middle of\n" ..
      "one.",
    example = "!$ call omp_set_default_device(mod(rank, omp_get_num_devices()))",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "device_num",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_default_device",
    see_also = {
      "omp_get_default_device",
      "DEVICE",
      "omp_get_num_devices",
    },
    signature = "omp_set_default_device(device_num)",
    standard = "OpenMP 4.0",
    summary = "Set the device used by target regions with no DEVICE clause",
  },
  omp_set_dynamic = {
    description = "When dynamic adjustment is enabled the runtime may give a parallel region FEWER\n" ..
      "threads than requested, according to system load. When it is disabled, the request\n" ..
      "is honoured exactly (up to the thread limit).\n" ..
      "\n" ..
      "Disable it — `call omp_set_dynamic(.false.)` — whenever the code depends on the\n" ..
      "team size: per-thread arrays indexed by thread number, threadprivate values\n" ..
      "persisting between regions, or a hand-partitioned decomposition. Benchmarks should\n" ..
      "disable it too, or the thread count varies between runs.",
    example = "!$ call omp_set_dynamic(.false.)\n" ..
      "!$ call omp_set_num_threads(8)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "dynamic_threads",
        type = "logical",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_dynamic",
    params = {
      dynamic_threads = "LOGICAL; .TRUE. permits the runtime to reduce team sizes.",
    },
    result = "Dynamic adjustment is enabled or disabled for later regions.",
    see_also = {
      "omp_get_dynamic",
      "omp_set_num_threads",
      "THREADPRIVATE",
    },
    signature = "omp_set_dynamic(dynamic_threads)",
    standard = "OpenMP 1.0",
    summary = "Enable or disable dynamic adjustment of the number of threads",
  },
  omp_set_lock = {
    description = "Blocks the calling thread until the lock is free, then owns it. The lock must have\n" ..
      "been initialised by `omp_init_lock` and must not already be owned by the calling\n" ..
      "thread — a simple lock is NOT recursive, so locking it twice from one thread is an\n" ..
      "immediate deadlock. That is what `omp_init_nest_lock` and its family are for.\n" ..
      "\n" ..
      "Entering and leaving a lock is a memory fence, so data written before the unlock is\n" ..
      "visible to the next owner.\n" ..
      "\n" ..
      "Blocking inside a task is a scheduling hazard: a TIED task that blocks holds its\n" ..
      "thread, and an `UNTIED` task may be resumed on a different thread, which makes\n" ..
      "releasing the lock invalid. Keep lock regions short and free of task scheduling\n" ..
      "points.",
    example = "call omp_set_lock(lck)\n" ..
      "count = count + 1\n" ..
      "call omp_unset_lock(lck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_lock",
    params = {
      svar = "The lock variable, declared `integer(kind=omp_lock_kind)`.",
    },
    result = "The lock is held by the calling thread on return.",
    see_also = {
      "omp_unset_lock",
      "omp_test_lock",
      "omp_init_lock",
      "omp_set_nest_lock",
    },
    signature = "omp_set_lock(svar)",
    standard = "OpenMP 1.0",
    summary = "Acquire a simple lock, blocking until it becomes available",
  },
  omp_set_max_active_levels = {
    description = "Sets `max-active-levels-var`. A value of 1 (the usual default together with nesting\n" ..
      "disabled) means an inner `PARALLEL` region is serialised to a team of one; 2 or more\n" ..
      "allows genuinely nested teams.\n" ..
      "\n" ..
      "Nested parallelism multiplies threads quickly — 8 outer times 8 inner is 64 threads\n" ..
      "on an 8-core node — so raise this only with a matching `NUM_THREADS` plan, and\n" ..
      "prefer tasks, which the runtime load-balances, to nested regions.",
    example = "!$ call omp_set_max_active_levels(2)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "max_levels",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_max_active_levels",
    params = {
      max_levels = "Maximum depth of active nested regions.",
    },
    result = "Nesting beyond **max_levels** runs serially.",
    see_also = {
      "omp_get_max_active_levels",
      "omp_get_level",
      "omp_get_active_level",
    },
    signature = "omp_set_max_active_levels(max_levels)",
    standard = "OpenMP 3.0",
    summary = "Set the maximum depth of nested ACTIVE parallel regions",
  },
  omp_set_nest_lock = {
    description = "If the calling thread already owns the lock, the nesting count is incremented and\n" ..
      "the call returns immediately; otherwise it blocks until the lock is free.\n" ..
      "\n" ..
      "Every acquisition must be matched by an `omp_unset_nest_lock`; the lock is released\n" ..
      "to other threads only when the count returns to zero.",
    example = "call omp_set_nest_lock(nlck)\n" ..
      "call recursive_update(node)\n" ..
      "call omp_unset_nest_lock(nlck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_nest_lock",
    params = {
      nvar = "The nestable lock variable.",
    },
    result = "The lock is held; its nesting count is incremented.",
    see_also = {
      "omp_unset_nest_lock",
      "omp_test_nest_lock",
      "omp_init_nest_lock",
    },
    signature = "omp_set_nest_lock(nvar)",
    standard = "OpenMP 2.0",
    summary = "Acquire a nestable lock, or increment its nesting count if already owned",
  },
  omp_set_nested = {
    description = "**Deprecated in OpenMP 5.0.** Use `omp_set_max_active_levels` instead:\n" ..
      "`omp_set_nested(.true.)` is equivalent to setting the maximum active levels to an\n" ..
      "implementation-defined value greater than one, and `.false.` to setting it to 1.\n" ..
      "\n" ..
      "Mixing the two interfaces is how a program ends up with nesting that is enabled\n" ..
      "according to one call and disabled according to the other; pick the levels\n" ..
      "interface and use it everywhere.",
    example = "!$ call omp_set_max_active_levels(2)   ! preferred over omp_set_nested(.true.)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "nested",
        type = "logical",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_nested",
    params = {
      nested = "LOGICAL; .TRUE. enables nested parallelism.",
    },
    result = "Nested parallelism is enabled or disabled.",
    see_also = {
      "omp_set_max_active_levels",
      "omp_get_nested",
      "omp_get_level",
    },
    signature = "omp_set_nested(nested)",
    standard = "OpenMP 1.0 (deprecated in 5.0)",
    summary = "Deprecated: enable or disable nested parallelism",
  },
  omp_set_num_teams = {
    interface = {
      {
        intent = "in",
        name = "num_teams",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_num_teams",
    signature = "omp_set_num_teams(num_teams)",
  },
  omp_set_num_threads = {
    description = "Sets the `nthreads-var` ICV for the calling thread, so parallel regions\n" ..
      "encountered afterwards request this many threads. It is overridden by a\n" ..
      "`NUM_THREADS` clause and it cannot resize a team that is already running.\n" ..
      "\n" ..
      "Calling it from inside a parallel region affects only nested regions created by the\n" ..
      "calling thread. In a hybrid MPI code, set it once per rank at start-up to the core\n" ..
      "budget the launcher gave that rank.",
    example = "!$ call omp_set_num_threads(4)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "num_threads",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_num_threads",
    params = {
      num_threads = "Number of threads to request; must be positive.",
    },
    result = "Later parallel regions request **num_threads** threads.",
    see_also = {
      "omp_get_max_threads",
      "omp_get_num_threads",
      "NUM_THREADS",
    },
    signature = "omp_set_num_threads(num_threads)",
    standard = "OpenMP 1.0",
    summary = "Set the number of threads for subsequent parallel regions",
  },
  omp_set_schedule = {
    description = "Sets the `run-sched-var` ICV for the calling thread. The first argument is one of\n" ..
      "the `omp_sched_kind` constants from `omp_lib_kinds` — `omp_sched_static`,\n" ..
      "`omp_sched_dynamic`, `omp_sched_guided`, `omp_sched_auto` — and the second is the\n" ..
      "chunk size, where a value less than 1 means 'the implementation default for that\n" ..
      "kind'.\n" ..
      "\n" ..
      "It affects only loops that carry `SCHEDULE(RUNTIME)`; every other loop keeps the\n" ..
      "schedule written on it. Together with `OMP_SCHEDULE` this is how a schedule can be\n" ..
      "tuned without recompiling — set `SCHEDULE(RUNTIME)` on the loop and choose the\n" ..
      "policy from the outside.\n" ..
      "\n" ..
      "The constants may also carry the monotonic/nonmonotonic modifier bits, which is why\n" ..
      "the kind parameter is an opaque `omp_sched_kind` rather than a plain integer.",
    example = "!$ use omp_lib\n" ..
      "!$ call omp_set_schedule(omp_sched_guided, 32)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "in",
        name = "kind",
        type = "integer(omp_sched_kind)",
      },
      {
        intent = "in",
        name = "chunk_size",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_schedule",
    params = {
      chunk_size = "Chunk size; the implementation's default is used when it is not positive.",
      kind = "Schedule kind: omp_sched_static, _dynamic, _guided or _auto.",
    },
    result = "Later `schedule(runtime)` loops use the given schedule.",
    see_also = {
      "omp_get_schedule",
      "SCHEDULE",
      "omp_lib_kinds",
    },
    signature = "omp_set_schedule(kind, chunk_size)",
    standard = "OpenMP 3.0",
    summary = "Set the schedule used by loops with SCHEDULE(RUNTIME)",
  },
  omp_set_teams_thread_limit = {
    interface = {
      {
        intent = "in",
        name = "thread_limit",
        type = "integer",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_set_teams_thread_limit",
    signature = "omp_set_teams_thread_limit(thread_limit)",
  },
  omp_sync_hint_contended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_contended",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "2",
  },
  omp_sync_hint_kind = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_kind",
    section = "omp_lib_kinds",
    type = "integer",
    value = "4",
  },
  omp_sync_hint_none = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_none",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "0",
  },
  omp_sync_hint_nonspeculative = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_nonspeculative",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "4",
  },
  omp_sync_hint_speculative = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_speculative",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "8",
  },
  omp_sync_hint_uncontended = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_sync_hint_uncontended",
    section = "omp_lib_kinds",
    type = "integer(omp_lock_hint_kind)",
    value = "1",
  },
  omp_target_alloc = {
    interface = {
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_alloc",
    result_type = "type(c_ptr)",
    signature = "omp_target_alloc(size, device_num)",
  },
  omp_target_associate_ptr = {
    interface = {
      {
        name = "host_ptr",
        type = "type(c_ptr)",
      },
      {
        name = "device_ptr",
        type = "type(c_ptr)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "device_offset",
        type = "integer(c_size_t)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_associate_ptr",
    result_type = "integer(c_int)",
    signature = "omp_target_associate_ptr(host_ptr, device_ptr, size, device_offset, device_num)",
  },
  omp_target_disassociate_ptr = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_disassociate_ptr",
    result_type = "integer(c_int)",
    signature = "omp_target_disassociate_ptr(ptr, device_num)",
  },
  omp_target_free = {
    interface = {
      {
        name = "device_ptr",
        type = "type(c_ptr)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_target_free",
    signature = "omp_target_free(device_ptr, device_num)",
  },
  omp_target_is_accessible = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "size",
        type = "integer(c_size_t)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_is_accessible",
    result_type = "integer(c_int)",
    signature = "omp_target_is_accessible(ptr, size, device_num)",
  },
  omp_target_is_present = {
    interface = {
      {
        name = "ptr",
        type = "type(c_ptr)",
      },
      {
        name = "device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_is_present",
    result_type = "integer(c_int)",
    signature = "omp_target_is_present(ptr, device_num)",
  },
  omp_target_memcpy = {
    interface = {
      {
        name = "dst",
        type = "type(c_ptr)",
      },
      {
        name = "src",
        type = "type(c_ptr)",
      },
      {
        name = "length",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_offset",
        type = "integer(c_size_t)",
      },
      {
        name = "src_offset",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_device_num",
        type = "integer(c_int)",
      },
      {
        name = "src_device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_memcpy",
    result_type = "integer(c_int)",
    signature = "omp_target_memcpy(dst, src, length, dst_offset, src_offset, dst_device_num, src_device_num)",
  },
  omp_target_memcpy_async = {
    interface = {
      {
        name = "dst",
        type = "type(c_ptr)",
      },
      {
        name = "src",
        type = "type(c_ptr)",
      },
      {
        name = "length",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_offset",
        type = "integer(c_size_t)",
      },
      {
        name = "src_offset",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_device_num",
        type = "integer(c_int)",
      },
      {
        name = "src_device_num",
        type = "integer(c_int)",
      },
      {
        name = "depobj_count",
        type = "integer(c_int)",
      },
      {
        dim = "(*)",
        name = "depobj_list",
        optional = true,
        type = "integer(omp_depend_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_memcpy_async",
    result_type = "integer(c_int)",
    signature = "omp_target_memcpy_async(dst, src, length, dst_offset, src_offset, dst_device_num, src_device_num, depobj_count, depobj_list)",
  },
  omp_target_memcpy_rect = {
    interface = {
      {
        name = "dst",
        type = "type(c_ptr)",
      },
      {
        name = "src",
        type = "type(c_ptr)",
      },
      {
        name = "element_size",
        type = "integer(c_size_t)",
      },
      {
        name = "num_dims",
        type = "integer(c_int)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "volume",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dst_offsets",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "src_offsets",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dst_dimensions",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "src_dimensions",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_device_num",
        type = "integer(c_int)",
      },
      {
        name = "src_device_num",
        type = "integer(c_int)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_memcpy_rect",
    result_type = "integer(c_int)",
    signature = "omp_target_memcpy_rect(dst, src, element_size, num_dims, volume, dst_offsets, src_offsets, dst_dimensions, src_dimensions, dst_device_num, src_device_num)",
  },
  omp_target_memcpy_rect_async = {
    interface = {
      {
        name = "dst",
        type = "type(c_ptr)",
      },
      {
        name = "src",
        type = "type(c_ptr)",
      },
      {
        name = "element_size",
        type = "integer(c_size_t)",
      },
      {
        name = "num_dims",
        type = "integer(c_int)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "volume",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dst_offsets",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "src_offsets",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "dst_dimensions",
        type = "integer(c_size_t)",
      },
      {
        dim = "(*)",
        intent = "in",
        name = "src_dimensions",
        type = "integer(c_size_t)",
      },
      {
        name = "dst_device_num",
        type = "integer(c_int)",
      },
      {
        name = "src_device_num",
        type = "integer(c_int)",
      },
      {
        name = "depobj_count",
        type = "integer(c_int)",
      },
      {
        dim = "(*)",
        name = "depobj_list",
        optional = true,
        type = "integer(omp_depend_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_target_memcpy_rect_async",
    result_type = "integer(c_int)",
    signature = "omp_target_memcpy_rect_async(dst, src, element_size, num_dims, volume, dst_offsets, src_offsets, dst_dimensions, src_dimensions, dst_device_num, src_device_num, depobj_count, depobj_list)",
  },
  omp_test_lock = {
    description = "Attempts to set the lock and returns immediately either way. If it returns\n" ..
      "`.true.` the calling thread now OWNS the lock and must unset it; if `.false.`, it\n" ..
      "does not own it and must not.\n" ..
      "\n" ..
      "The pattern it enables is 'do some other useful work and try again later', which\n" ..
      "keeps a thread busy instead of blocking on a contended structure.",
    example = "do while (.not. omp_test_lock(lck))\n" ..
      "  call do_other_work()\n" ..
      "end do\n" ..
      "call update()\n" ..
      "call omp_unset_lock(lck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_test_lock",
    params = {
      svar = "The lock variable to try.",
    },
    result = "`.true.` if the lock was acquired (the caller now owns it), `.false.` if it was already held.",
    result_type = "logical",
    see_also = {
      "omp_set_lock",
      "omp_unset_lock",
      "omp_test_nest_lock",
    },
    signature = "omp_test_lock(svar)",
    standard = "OpenMP 1.0",
    summary = "Try to acquire a simple lock without blocking",
  },
  omp_test_nest_lock = {
    description = "Unlike `omp_test_lock`, this returns an INTEGER, not a logical: the new nesting\n" ..
      "count on success, or 0 if the lock could not be acquired. A non-zero result means\n" ..
      "the caller owns the lock and owes exactly that many unset calls in total.",
    example = "if (omp_test_nest_lock(nlck) > 0) then\n" ..
      "  call update()\n" ..
      "  call omp_unset_nest_lock(nlck)\n" ..
      "end if",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
    },
    kind = "function",
    module = "omp_lib",
    name = "omp_test_nest_lock",
    params = {
      nvar = "The nestable lock variable to try.",
    },
    result = "The new nesting count if the lock was acquired, or 0 if it was held by another thread.",
    result_type = "integer",
    see_also = {
      "omp_set_nest_lock",
      "omp_unset_nest_lock",
      "omp_test_lock",
    },
    signature = "omp_test_nest_lock(nvar)",
    standard = "OpenMP 2.0",
    summary = "Try to acquire a nestable lock without blocking, returning the new nesting count",
  },
  omp_thread_mem_alloc = {
    kind = "constant",
    module = "omp_lib",
    name = "omp_thread_mem_alloc",
    section = "omp_lib_kinds",
    type = "integer(omp_allocator_handle_kind)",
    value = "8",
  },
  omp_unset_lock = {
    description = "Releases the lock and lets one waiting thread proceed. Only the OWNING thread may\n" ..
      "unset it; unsetting a lock the thread does not own, or one that is not locked, is\n" ..
      "undefined behaviour and typically corrupts the runtime's state rather than raising\n" ..
      "an error.\n" ..
      "\n" ..
      "Every path out of the protected region must unset the lock — including error paths.\n" ..
      "Fortran has no `finally`, so structure the region so there is exactly one exit.",
    example = "call omp_set_lock(lck)\n" ..
      "call update_shared_table()\n" ..
      "call omp_unset_lock(lck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "svar",
        type = "integer(omp_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_unset_lock",
    params = {
      svar = "The lock variable, currently held by this thread.",
    },
    result = "The lock is released.",
    see_also = {
      "omp_set_lock",
      "omp_test_lock",
      "omp_destroy_lock",
    },
    signature = "omp_unset_lock(svar)",
    standard = "OpenMP 1.0",
    summary = "Release a simple lock owned by the calling thread",
  },
  omp_unset_nest_lock = {
    description = "Decrements the count; the lock becomes available to other threads only when the\n" ..
      "count reaches zero. Only the owning thread may call it.\n" ..
      "\n" ..
      "An unbalanced call leaves the lock permanently held — the classic cause of a hang\n" ..
      "that appears only under load, because the imbalance is usually on an error path.",
    example = "call omp_unset_nest_lock(nlck)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    interface = {
      {
        intent = "inout",
        name = "nvar",
        type = "integer(omp_nest_lock_kind)",
      },
    },
    kind = "subroutine",
    module = "omp_lib",
    name = "omp_unset_nest_lock",
    params = {
      nvar = "The nestable lock variable.",
    },
    result = "The nesting count is decremented; the lock frees at zero.",
    see_also = {
      "omp_set_nest_lock",
      "omp_test_nest_lock",
      "omp_destroy_nest_lock",
    },
    signature = "omp_unset_nest_lock(nvar)",
    standard = "OpenMP 2.0",
    summary = "Decrement a nestable lock's nesting count, releasing it at zero",
  },
  openmp_version = {
    kind = "constant",
    module = "omp_lib",
    name = "openmp_version",
    section = "omp_lib",
    type = "integer",
    value = "201511",
  },
  order = {
    description = "`ORDER(CONCURRENT)` tells the implementation that the iterations are independent\n" ..
      "and may be executed in any order, including simultaneously in threads and vector\n" ..
      "lanes — the same promise `do concurrent` makes in Fortran, and it lifts the\n" ..
      "scheduling constraints a worksharing loop normally carries.\n" ..
      "\n" ..
      "The body is then restricted in the way a `LOOP` construct's body is: no ordered\n" ..
      "regions, no constructs that would require a specific iteration-to-thread mapping,\n" ..
      "and no threadprivate state relied on across iterations.\n" ..
      "\n" ..
      "OpenMP 5.1 added the modifiers: `REPRODUCIBLE` asks for a mapping that is the same\n" ..
      "between two loops with the same shape, `UNCONSTRAINED` gives the implementation\n" ..
      "full freedom.",
    example = "!$omp do order(concurrent)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "ORDER",
    see_also = {
      "LOOP",
      "concurrent",
      "SIMD",
      "COLLAPSE",
    },
    signature = "ORDER([reproducible | unconstrained:] CONCURRENT)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Assert that the loop's iterations may execute in any order",
    valid_on = {
      "DO",
      "SIMD",
      "DO SIMD",
      "DISTRIBUTE",
      "LOOP",
    },
  },
  ordered = {
    clauses = {
      "DEPEND",
      "THREADS",
      "SIMD",
    },
    description = "Two things share the word. As a CLAUSE on a worksharing loop, `ORDERED` states\n" ..
      "that the loop contains an ordered region; as a DIRECTIVE inside the loop body, it\n" ..
      "marks the block that must be executed in the order the iterations would run\n" ..
      "serially.\n" ..
      "\n" ..
      "The pair is how a parallel loop performs ordered I/O, or appends to a list in a\n" ..
      "reproducible order, while the rest of the body runs in parallel. Each iteration\n" ..
      "may encounter the ordered region at most once, and threads block until their turn,\n" ..
      "so an ordered region on the critical path serialises the loop.\n" ..
      "\n" ..
      "With `ORDERED(n)` on the loop plus `!$OMP ORDERED DEPEND(SINK: i-1)` and\n" ..
      "`!$OMP ORDERED DEPEND(SOURCE)` in the body (OpenMP 4.5) the construct expresses\n" ..
      "DOACROSS pipelining across n loop levels — a wavefront sweep without a barrier per\n" ..
      "level. In OpenMP 5.2 the `DEPEND` spelling on ordered is deprecated in favour of\n" ..
      "`DOACROSS`.",
    example = "!$omp parallel do ordered schedule(static, 1)\n" ..
      "do i = 1, n\n" ..
      "  call compute(i, res)\n" ..
      "  !$omp ordered\n" ..
      "  write(unit, *) i, res\n" ..
      "  !$omp end ordered\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "ORDERED",
    see_also = {
      "DO",
      "DEPEND",
      "CRITICAL",
      "SCHEDULE",
    },
    signature = "!$OMP ORDERED [(n)] [DEPEND(...)]   ! also a clause: ORDERED[(n)] on DO",
    standard = "OpenMP 5.2",
    summary = "Execute part of a worksharing loop's body in sequential iteration order",
    valid_on = {
      "DO",
      "PARALLEL DO",
      "DO SIMD",
    },
  },
  parallel = {
    clauses = {
      "IF",
      "NUM_THREADS",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "SHARED",
      "COPYIN",
      "REDUCTION",
      "PROC_BIND",
      "ALLOCATE",
    },
    description = "The encountering thread becomes the primary thread of a new team and every thread\n" ..
      "in the team executes the SAME block — this directive replicates work, it does not\n" ..
      "divide it. Division needs a worksharing construct (`DO`, `SECTIONS`, `WORKSHARE`,\n" ..
      "`SINGLE`) inside the region.\n" ..
      "\n" ..
      "`!$OMP END PARALLEL` is required and carries an implicit barrier: all threads\n" ..
      "join there, and `NOWAIT` is not allowed on it. Team size is decided by, in order\n" ..
      "of precedence, a `NUM_THREADS` clause, `omp_set_num_threads`, the `OMP_NUM_THREADS`\n" ..
      "environment variable, and finally the implementation default.\n" ..
      "\n" ..
      "In Fortran the default data-sharing attribute is SHARED for everything the block\n" ..
      "inherits, except the loop iteration variables of enclosed worksharing loops. That\n" ..
      "default is the origin of most races; write `DEFAULT(NONE)` and name every\n" ..
      "variable, which turns a forgotten `PRIVATE` into a compile error instead of a\n" ..
      "wrong answer at scale.\n" ..
      "\n" ..
      "A construct encountered inside the region but lexically outside it — in a\n" ..
      "procedure called from the region — is ORPHANED. Orphaned worksharing binds to the\n" ..
      "innermost enclosing parallel region at run time; if there is none, it binds to an\n" ..
      "implicit team of one and simply runs serially, which is why a `!$OMP DO` inside a\n" ..
      "helper routine silently does nothing when the caller forgot its `PARALLEL`.",
    example = "!$omp parallel default(none) shared(a, n) private(i)\n" ..
      "!$omp do\n" ..
      "do i = 1, n\n" ..
      "  a(i) = 2.0_dp * a(i)\n" ..
      "end do\n" ..
      "!$omp end do\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "PARALLEL",
    params = {
      ["allocate([allocator:]list)"] = "Specifies the memory allocator for private variables.",
      ["copyin(list)"] = "Copies the master thread's THREADPRIVATE common block data to the thread-private copies at the start of the parallel region.",
      ["default(none|shared|private|firstprivate)"] = "Sets the default data-sharing attribute for variables referenced in the parallel region. Using `none` requires explicit specification of all variables. Only one DEFAULT clause is allowed per directive.",
      ["firstprivate(list)"] = "Like private, but each thread's copy is initialized from the original variable's value before the parallel region.",
      ["if([parallel:]scalar-logical-expression)"] = "If the expression evaluates to .false., the region executes serially with a single thread.",
      ["num_threads(scalar-integer-expression)"] = "Specifies the number of threads in the team. Must evaluate to a positive integer. Overrides OMP_NUM_THREADS environment variable.",
      ["private(list)"] = "Creates a new instance of each listed variable for each thread. The initial value is undefined. Variables must be definable.",
      ["proc_bind(master|close|spread)"] = "Specifies the mapping of threads to places. `master` binds threads to the master's place, `close` binds to places close to the master, `spread` distributes threads across available places.",
      ["reduction([modifier,]operator:list)"] = "Performs a reduction operation. Each thread has a private copy initialized appropriately. At region end, values are combined using the specified operator (+, *, -, .and., .or., .eqv., .neqv., max, min, iand, ior, ieor).",
      ["shared(list)"] = "Specifies that listed variables are shared among all threads in the team. All threads access the same storage location.",
    },
    result = "The parallel construct creates a team of threads that execute the structured block concurrently. Upon completion of the parallel region, all threads synchronize at an implicit barrier, ensuring all parallel work is complete. Only the master thread (thread 0) continues execution after the parallel region. Any reduction variables contain the combined result from all threads. Private variables go out of scope at the end of the region.",
    see_also = {
      "DO",
      "PARALLEL DO",
      "DEFAULT",
      "NUM_THREADS",
      "omp_get_thread_num",
    },
    signature = "!$OMP PARALLEL [clauses]",
    standard = "OpenMP 5.2",
    summary = "Create a team of threads that all execute the enclosed block",
  },
  parallel_do = {
    clauses = {
      "IF",
      "NUM_THREADS",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "SHARED",
      "COPYIN",
      "REDUCTION",
      "PROC_BIND",
      "SCHEDULE",
      "COLLAPSE",
      "ORDERED",
      "LINEAR",
      "ALLOCATE",
      "ORDER",
    },
    description = "Semantically identical to a `PARALLEL` region containing a single `DO` and nothing\n" ..
      "else, and it accepts the union of both directives' clauses. `NOWAIT` is NOT among\n" ..
      "them: the parallel region's closing barrier cannot be removed.\n" ..
      "\n" ..
      "This is the right form for the common case of one loop — it makes the scope of\n" ..
      "the team obvious and avoids the mistake of leaving other statements inside the\n" ..
      "region where every thread would execute them redundantly.\n" ..
      "\n" ..
      "`!$OMP END PARALLEL DO` is optional. To parallelise several loops without paying\n" ..
      "for repeated team creation, open one `PARALLEL` region and use separate `!$OMP DO`\n" ..
      "constructs inside it.",
    example = "!$omp parallel do default(none) shared(a, b, n) private(i) schedule(static)\n" ..
      "do i = 1, n\n" ..
      "  a(i) = a(i) + b(i)\n" ..
      "end do\n" ..
      "!$omp end parallel do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "PARALLEL DO",
    see_also = {
      "PARALLEL",
      "DO",
      "PARALLEL DO SIMD",
      "SCHEDULE",
    },
    signature = "!$OMP PARALLEL DO [clauses]",
    standard = "OpenMP 5.2",
    summary = "Combined construct: a parallel region containing one worksharing loop",
  },
  parallel_do_simd = {
    clauses = {
      "IF",
      "NUM_THREADS",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "SHARED",
      "COPYIN",
      "REDUCTION",
      "PROC_BIND",
      "SCHEDULE",
      "COLLAPSE",
      "SAFELEN",
      "SIMDLEN",
      "LINEAR",
      "ALIGNED",
      "ORDER",
      "ALLOCATE",
    },
    description = "Equivalent to `PARALLEL` containing a single `DO SIMD`. It accepts every clause of\n" ..
      "the three constructs except `NOWAIT`, which the closing barrier of the parallel\n" ..
      "region makes meaningless.\n" ..
      "\n" ..
      "This is the usual one-line spelling for a numerically simple loop that should use\n" ..
      "both threads and vector units. Measure before assuming it beats `PARALLEL DO`\n" ..
      "alone: for a memory-bound loop the vector clause changes nothing, and for a short\n" ..
      "loop the team creation dominates.\n" ..
      "\n" ..
      "Introduced in OpenMP 4.0.",
    example = "!$omp parallel do simd default(none) shared(x, y, a, n) private(i)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "PARALLEL DO SIMD",
    see_also = {
      "PARALLEL DO",
      "DO SIMD",
      "SIMD",
    },
    signature = "!$OMP PARALLEL DO SIMD [clauses]",
    standard = "OpenMP 5.2",
    summary = "Combined construct: parallel region, worksharing loop and vectorisation",
  },
  parallel_sections = {
    clauses = {
      "IF",
      "NUM_THREADS",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "SHARED",
      "COPYIN",
      "REDUCTION",
      "PROC_BIND",
      "ALLOCATE",
    },
    description = "Equivalent to a `PARALLEL` region whose only content is a `SECTIONS` construct,\n" ..
      "and it accepts the union of their clauses. `NOWAIT` is not allowed — the parallel\n" ..
      "region's closing barrier stays.\n" ..
      "\n" ..
      "Requires `!$OMP END PARALLEL SECTIONS`. If more threads are available than there\n" ..
      "are sections, the surplus threads simply wait at the barrier.",
    example = "!$omp parallel sections default(none) shared(u, v)\n" ..
      "!$omp section\n" ..
      "call halo_exchange(u)\n" ..
      "!$omp section\n" ..
      "call interior_update(v)\n" ..
      "!$omp end parallel sections",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "PARALLEL SECTIONS",
    see_also = {
      "SECTIONS",
      "SECTION",
      "PARALLEL",
    },
    signature = "!$OMP PARALLEL SECTIONS [clauses]",
    standard = "OpenMP 5.2",
    summary = "Combined construct: a parallel region containing one SECTIONS construct",
  },
  parallel_workshare = {
    clauses = {
      "IF",
      "NUM_THREADS",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "SHARED",
      "COPYIN",
      "REDUCTION",
      "PROC_BIND",
      "ALLOCATE",
    },
    description = "Equivalent to `PARALLEL` containing a single `WORKSHARE` construct; accepts the\n" ..
      "parallel clauses, but not `NOWAIT`. Requires `!$OMP END PARALLEL WORKSHARE`.\n" ..
      "\n" ..
      "This is the shortest way to parallelise a block of Fortran array expressions, and\n" ..
      "it is Fortran-only — there is no C or C++ counterpart.",
    example = "!$omp parallel workshare\n" ..
      "a = b * c\n" ..
      "s = sum(a)\n" ..
      "!$omp end parallel workshare",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "PARALLEL WORKSHARE",
    see_also = {
      "WORKSHARE",
      "PARALLEL",
      "DO",
    },
    signature = "!$OMP PARALLEL WORKSHARE [clauses]",
    standard = "OpenMP 5.2",
    summary = "Combined construct: a parallel region containing one WORKSHARE construct",
  },
  priority = {
    description = "A non-negative integer hint, capped at `omp_get_max_task_priority()`; values above\n" ..
      "the cap are clamped, and the maximum is 0 unless `OMP_MAX_TASK_PRIORITY` is set —\n" ..
      "so on a default run the clause does nothing at all, which explains most 'priority\n" ..
      "has no effect' reports.\n" ..
      "\n" ..
      "Even when enabled it is only a hint: the runtime may ignore it entirely, and it\n" ..
      "says nothing about task ORDER, only about preference when several are ready. Never\n" ..
      "use it for correctness — express real ordering with `DEPEND`.\n" ..
      "\n" ..
      "The legitimate use is putting critical-path tasks (the ones others depend on)\n" ..
      "ahead of the bulk.",
    example = "!$omp task priority(10) depend(out: pivot)\n" ..
      "call factor_pivot(pivot)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "PRIORITY",
    see_also = {
      "TASK",
      "DEPEND",
      "omp_get_max_task_priority",
    },
    signature = "PRIORITY(priority-value)",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Hint that this task should be scheduled before lower-priority ones",
    valid_on = {
      "TASK",
      "TASKLOOP",
    },
  },
  private = {
    description = "The value is **undefined** on entry and the original variable is **unchanged** on\n" ..
      "exit. A private copy is a NEW variable of the same type and shape, so anything the\n" ..
      "thread needs from the original must be copied in explicitly — that is what\n" ..
      "`FIRSTPRIVATE` is for — and anything it computes is lost unless `LASTPRIVATE` or a\n" ..
      "reduction carries it out.\n" ..
      "\n" ..
      "In Fortran the default sharing attribute inside a parallel region is SHARED, so\n" ..
      "every scratch variable used in the body needs naming here. The loop iteration\n" ..
      "variable of a worksharing `DO` is private automatically, as are the indices of\n" ..
      "loops fused by `COLLAPSE`, and variables declared inside a `BLOCK` construct in\n" ..
      "the region.\n" ..
      "\n" ..
      "Privatising an allocatable gives each thread an UNALLOCATED copy; privatising a\n" ..
      "pointer gives an undefined association status. Both must be set up inside the\n" ..
      "region. A variable with the `SAVE` attribute, a common block member or a module\n" ..
      "variable cannot be privatised this way — use `THREADPRIVATE`.",
    example = "!$omp parallel do private(i, tmp)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "PRIVATE",
    see_also = {
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "SHARED",
    },
    signature = "PRIVATE(list)",
    standard = "OpenMP 5.2 §5.4.3",
    summary = "Give each thread its own uninitialized copy of each variable",
    valid_on = {
      "PARALLEL",
      "DO",
      "SECTIONS",
      "SINGLE",
      "TASK",
      "SIMD",
      "TARGET",
      "TEAMS",
    },
  },
  proc_bind = {
    description = "`PRIMARY` (called `MASTER` before OpenMP 5.1, still accepted and deprecated) puts\n" ..
      "every thread in the same place as the primary thread. `CLOSE` assigns threads to\n" ..
      "places near the primary one, filling each place before moving on — right for\n" ..
      "sharing a cache. `SPREAD` distributes the team sparsely over the place list —\n" ..
      "right for maximising memory bandwidth and for NUMA-aware first touch.\n" ..
      "\n" ..
      "The place list itself comes from `OMP_PLACES` (`cores`, `threads`, `sockets`, or an\n" ..
      "explicit list) and the clause has no effect unless binding is enabled, which\n" ..
      "`OMP_PROC_BIND` or this clause does.\n" ..
      "\n" ..
      "Binding matters enormously on multi-socket nodes: without it the OS migrates\n" ..
      "threads across sockets and every migration invalidates the first-touch NUMA\n" ..
      "placement of the arrays the thread was working on. In hybrid MPI+OpenMP runs,\n" ..
      "binding must be coordinated with the launcher's own affinity settings, or the two\n" ..
      "fight and every rank lands on core 0.",
    example = "!$omp parallel proc_bind(spread) num_threads(nsockets)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "PROC_BIND",
    see_also = {
      "NUM_THREADS",
      "omp_get_proc_bind",
      "omp_get_num_places",
    },
    signature = "PROC_BIND(PRIMARY | MASTER | CLOSE | SPREAD)",
    standard = "OpenMP 5.2",
    summary = "Control how the team's threads are bound to the places of the machine",
    valid_on = {
      "PARALLEL",
      "PARALLEL DO",
      "PARALLEL SECTIONS",
      "PARALLEL WORKSHARE",
    },
  },
  read = {
    description = "`!$OMP ATOMIC READ` applies to a statement of the form `v = x`, guaranteeing that\n" ..
      "`x` is read in one indivisible operation — no torn value even if the type is wider\n" ..
      "than a machine word or the location is being updated concurrently.\n" ..
      "\n" ..
      "It does not order anything else unless a memory-order clause (`ACQUIRE`,\n" ..
      "`SEQ_CST`) is added. Reading a shared variable without it while another thread\n" ..
      "writes it is a data race, whatever the width.",
    example = "!$omp atomic read\n" ..
      "local = counter",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "READ",
    see_also = {
      "ATOMIC",
      "WRITE",
      "UPDATE",
      "CAPTURE",
      "ACQUIRE",
    },
    signature = "READ",
    standard = "OpenMP 5.2",
    summary = "ATOMIC form: make a single load of a memory location indivisible",
    valid_on = {
      "ATOMIC",
    },
  },
  reduction = {
    description = "Each thread gets a private copy initialised to the identity of the operator,\n" ..
      "accumulates into it with no synchronisation, and at the end of the region the\n" ..
      "copies are combined into the original variable — which itself takes part, so its\n" ..
      "value before the region is included exactly once.\n" ..
      "\n" ..
      "The Fortran operators and intrinsics, with the initial value of each private copy:\n" ..
      "\n" ..
      "- `+` — 0\n" ..
      "- `*` — 1\n" ..
      "- `-` — 0 (deprecated in OpenMP 5.2; it is just `+` with the sign already applied)\n" ..
      "- `.and.` — `.true.`\n" ..
      "- `.or.` — `.false.`\n" ..
      "- `.eqv.` — `.true.`\n" ..
      "- `.neqv.` — `.false.`\n" ..
      "- `max` — the smallest representable value of the type (`-huge(x)` for reals)\n" ..
      "- `min` — the largest representable value (`huge(x)`)\n" ..
      "- `iand` — all bits set (`not(0)`)\n" ..
      "- `ior` — 0\n" ..
      "- `ieor` — 0\n" ..
      "\n" ..
      "The reduction variable must not be accessed for anything but the reduction inside\n" ..
      "the region, and must be a scalar or an array (array reductions are allowed in\n" ..
      "Fortran, and cost a private copy of the whole array per thread).\n" ..
      "\n" ..
      "**Floating-point reductions are not reproducible**: the combination order is\n" ..
      "unspecified, so the result varies with thread count and between runs. Where bitwise\n" ..
      "reproducibility matters, accumulate per-thread partials into an indexed array and\n" ..
      "sum them in a fixed order.\n" ..
      "\n" ..
      "Modifiers: `INSCAN` pairs with the `SCAN` directive for prefix sums, `TASK` defers\n" ..
      "combination to task completion, `DEFAULT` is the normal behaviour. Derived types\n" ..
      "and custom operations need `DECLARE REDUCTION`.",
    example = "!$omp parallel do reduction(+:total) reduction(max:peak)\n" ..
      "do i = 1, n\n" ..
      "  total = total + a(i)\n" ..
      "  peak = max(peak, abs(a(i)))\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "REDUCTION",
    params = {
      [" * (multiplication)"] = "Identity value: 1. Combines partial products from all threads.",
      ["+ (addition)"] = "Identity value: 0. Combines partial sums from all threads.",
      ["- (subtraction)"] = "Identity value: 0. Note: Subtraction is not truly associative; treated as addition of negated values.",
      [".and. (logical AND)"] = "Identity value: .true.. Result is .true. only if all partial results are .true..",
      [".eqv. (logical equivalence)"] = "Identity value: .true.. Tests if all partial results have the same logical value.",
      [".neqv. (logical non-equivalence)"] = "Identity value: .false.. Logical XOR across all threads.",
      [".or. (logical OR)"] = "Identity value: .false.. Result is .true. if any partial result is .true..",
      ["iand (bitwise AND)"] = "Identity value: all bits set to 1. Performs bitwise AND across all threads.",
      ["ieor (bitwise XOR)"] = "Identity value: 0. Performs bitwise XOR across all threads.",
      ["ior (bitwise OR)"] = "Identity value: 0. Performs bitwise OR across all threads.",
      ["max (maximum)"] = "Identity value: smallest representable value for the type. Finds maximum across all threads.",
      ["min (minimum)"] = "Identity value: largest representable value for the type. Finds minimum across all threads.",
    },
    result = "After the parallel region completes, the reduction variable contains the combined result of the reduction operation applied across all threads. The order of combination is implementation-defined but mathematically equivalent to sequential execution for associative operators.",
    see_also = {
      "IN_REDUCTION",
      "TASK_REDUCTION",
      "DECLARE REDUCTION",
      "ATOMIC",
      "SCAN",
    },
    signature = "REDUCTION([modifier,] operator : list)",
    standard = "OpenMP 5.2",
    summary = "Combine each thread's private partial result into the original variable",
    valid_on = {
      "PARALLEL",
      "DO",
      "SECTIONS",
      "SIMD",
      "TASKLOOP",
      "TEAMS",
      "DISTRIBUTE",
      "LOOP",
    },
  },
  relaxed = {
    description = "The operation is indivisible — no lost updates on THIS location — but it imposes no\n" ..
      "ordering on any other memory access, and other threads may observe the surrounding\n" ..
      "writes in a different order.\n" ..
      "\n" ..
      "It is the default for `ATOMIC` unless `REQUIRES ATOMIC_DEFAULT_MEM_ORDER` says\n" ..
      "otherwise, and it is the right choice for a statistics counter or a histogram bin\n" ..
      "whose value is only read after a barrier.\n" ..
      "\n" ..
      "It is the wrong choice for a flag that guards other data: use `RELEASE` and\n" ..
      "`ACQUIRE`, or a `FLUSH` pair.",
    example = "!$omp atomic update relaxed\n" ..
      "hits = hits + 1",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "RELAXED",
    see_also = {
      "SEQ_CST",
      "ACQUIRE",
      "RELEASE",
      "ATOMIC",
    },
    signature = "RELAXED",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Memory order: atomicity only, with no ordering guarantees for other variables",
    valid_on = {
      "ATOMIC",
    },
  },
  release = {
    description = "The producer half of a release/acquire pair: everything this thread wrote before\n" ..
      "the release is visible to any thread that afterwards reads the same location with\n" ..
      "`ACQUIRE` ordering.\n" ..
      "\n" ..
      "Valid on atomic WRITE, UPDATE and CAPTURE operations and on `FLUSH`; not on an\n" ..
      "atomic READ.\n" ..
      "\n" ..
      "This is the idiom for publishing data with a flag, and it is cheaper than\n" ..
      "`SEQ_CST` because it constrains only one direction.",
    example = "data = compute()\n" ..
      "!$omp atomic write release\n" ..
      "flag = 1",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "RELEASE",
    see_also = {
      "ACQUIRE",
      "ACQ_REL",
      "SEQ_CST",
      "ATOMIC",
      "FLUSH",
    },
    signature = "RELEASE",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Memory order: no memory operation before this one may be reordered after it",
    valid_on = {
      "ATOMIC",
      "FLUSH",
    },
  },
  requires = {
    clauses = {
      "UNIFIED_SHARED_MEMORY",
      "UNIFIED_ADDRESS",
      "REVERSE_OFFLOAD",
      "ATOMIC_DEFAULT_MEM_ORDER",
      "DYNAMIC_ALLOCATORS",
      "SELF_MAPS",
    },
    description = "A declarative directive stating features the implementation must provide for this\n" ..
      "compilation unit; if it cannot, the program does not compile or does not run —\n" ..
      "which is the point, because the alternative is silently wrong offload code.\n" ..
      "\n" ..
      "`UNIFIED_SHARED_MEMORY` says host and device share memory, so `MAP` clauses become\n" ..
      "unnecessary and pointers are valid on both sides. `UNIFIED_ADDRESS` is the weaker\n" ..
      "promise that addresses are comparable. `ATOMIC_DEFAULT_MEM_ORDER(SEQ_CST|ACQ_REL|RELAXED)`\n" ..
      "changes the default memory ordering of every `ATOMIC` in the unit.\n" ..
      "`REVERSE_OFFLOAD` allows a `TARGET` region on the device to execute a region back\n" ..
      "on the host.\n" ..
      "\n" ..
      "The directive applies to the whole compilation unit and every unit in the program\n" ..
      "that uses the same device data must agree, so put it in a common header or module\n" ..
      "rather than in one file.",
    example = "!$omp requires unified_shared_memory",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "REQUIRES",
    see_also = {
      "TARGET",
      "MAP",
      "ATOMIC",
      "METADIRECTIVE",
    },
    signature = "!$OMP REQUIRES clause [, clause]",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Declare features the implementation must provide for this compilation unit",
  },
  safelen = {
    description = "`SAFELEN(4)` promises that no two iterations less than 4 apart are dependent, so\n" ..
      "the compiler may use vectors of at most 4 lanes. It is the way to vectorise a loop\n" ..
      "that DOES have a cross-iteration dependence, as long as the dependence distance is\n" ..
      "known and larger than the vector length.\n" ..
      "\n" ..
      "Getting it wrong gives wrong answers with no diagnostic — the compiler trusts the\n" ..
      "number completely.\n" ..
      "\n" ..
      "`SIMDLEN` is the other half of the pair and means something different: it is a\n" ..
      "preferred vector length, not a safety bound.",
    example = "!$omp simd safelen(8)\n" ..
      "do i = 9, n\n" ..
      "  a(i) = a(i-8) + b(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "SAFELEN",
    see_also = {
      "SIMD",
      "SIMDLEN",
      "ALIGNED",
      "LINEAR",
    },
    signature = "SAFELEN(length)",
    standard = "OpenMP 5.2",
    summary = "Maximum number of iterations that may safely execute concurrently in SIMD lanes",
    valid_on = {
      "SIMD",
      "DO SIMD",
    },
  },
  scan = {
    clauses = {
      "INCLUSIVE",
      "EXCLUSIVE",
    },
    description = "Computes a prefix sum (scan) in parallel. It is written inside a worksharing loop\n" ..
      "whose reduction clause carries the `INSCAN` modifier\n" ..
      "(`REDUCTION(INSCAN, +: s)`), and it splits the body into two phases: the input\n" ..
      "phase before the directive, which updates the scan variable, and the scan phase\n" ..
      "after it, which uses the running value.\n" ..
      "\n" ..
      "`INCLUSIVE(s)` makes iteration i see the sum up to and including i; `EXCLUSIVE(s)`\n" ..
      "up to but excluding i.\n" ..
      "\n" ..
      "The body is restricted — the scan variable may only be updated in the input phase\n" ..
      "and only read in the scan phase — and violating that gives wrong answers silently.\n" ..
      "Introduced in OpenMP 5.0.",
    example = "!$omp parallel do reduction(inscan, +: run)\n" ..
      "do i = 1, n\n" ..
      "  run = run + a(i)\n" ..
      "  !$omp scan inclusive(run)\n" ..
      "  p(i) = run\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "SCAN",
    see_also = {
      "REDUCTION",
      "DO",
      "ORDERED",
    },
    signature = "!$OMP SCAN INCLUSIVE(list) | EXCLUSIVE(list)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Compute a parallel prefix sum inside a loop with an INSCAN reduction",
  },
  schedule = {
    description = "The kinds:\n" ..
      "\n" ..
      "- `STATIC` — iterations are divided into chunks of `chunk_size` (or into one\n" ..
      "  roughly equal block per thread when omitted) and assigned round-robin BEFORE the\n" ..
      "  loop runs. No runtime overhead, perfect locality, and it is the only kind whose\n" ..
      "  mapping is reproducible between two loops with the same bounds — which is what\n" ..
      "  makes `NOWAIT` between two static loops safe.\n" ..
      "- `DYNAMIC` — each thread takes the next chunk when it finishes the last (default\n" ..
      "  chunk 1). Handles load imbalance; costs a synchronised counter per chunk, so\n" ..
      "  chunk 1 on a short body is slower than static.\n" ..
      "- `GUIDED` — like dynamic, but chunk sizes start large and shrink towards\n" ..
      "  `chunk_size`. A good default for unknown, moderate imbalance.\n" ..
      "- `AUTO` — the implementation or runtime decides; gfortran treats it as static.\n" ..
      "- `RUNTIME` — taken from the `OMP_SCHEDULE` environment variable or\n" ..
      "  `omp_set_schedule`, and reported by `omp_get_schedule`. No chunk size may be\n" ..
      "  given.\n" ..
      "\n" ..
      "Modifiers (OpenMP 4.5+): `MONOTONIC` guarantees each thread's iterations are\n" ..
      "increasing, `NONMONOTONIC` allows the runtime to hand out work in any order\n" ..
      "(the default for `DYNAMIC` and `GUIDED` since 5.0, and a real speed-up on\n" ..
      "contended loops), `SIMD` adjusts chunk sizes to the vector length.\n" ..
      "\n" ..
      "Rule of thumb: `STATIC` for uniform work, `GUIDED` or `DYNAMIC` with a chunk large\n" ..
      "enough to amortise the counter (tens to hundreds of iterations) for triangular\n" ..
      "loops, adaptive kernels and anything with a data-dependent body.",
    example = "!$omp parallel do schedule(guided, 32)\n" ..
      "do i = 1, n\n" ..
      "  call variable_cost_work(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "SCHEDULE",
    see_also = {
      "DO",
      "DIST_SCHEDULE",
      "omp_set_schedule",
      "omp_get_schedule",
      "NOWAIT",
    },
    signature = "SCHEDULE([modifier:] kind[, chunk_size])",
    standard = "OpenMP 5.2",
    summary = "Choose how loop iterations are distributed across the threads of the team",
    valid_on = {
      "DO",
      "PARALLEL DO",
      "DO SIMD",
      "PARALLEL DO SIMD",
    },
  },
  section = {
    clauses = {},
    description = "Takes no clauses and must appear only inside a `SECTIONS` or `PARALLEL SECTIONS`\n" ..
      "construct. Each `SECTION` block is executed exactly once by some thread of the\n" ..
      "team.\n" ..
      "\n" ..
      "The block before the first `SECTION` directive belongs to the construct too, so a\n" ..
      "`SECTIONS` construct with two blocks needs only one `SECTION` directive — a\n" ..
      "frequent source of confusion when counting sections.",
    example = "!$omp sections\n" ..
      "call phase_a()\n" ..
      "!$omp section\n" ..
      "call phase_b()\n" ..
      "!$omp end sections",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "SECTION",
    see_also = {
      "SECTIONS",
      "PARALLEL SECTIONS",
    },
    signature = "!$OMP SECTION",
    standard = "OpenMP 5.2",
    summary = "Delimit one block within a SECTIONS construct",
  },
  sections = {
    clauses = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "REDUCTION",
      "NOWAIT",
      "ALLOCATE",
    },
    description = "Each `!$OMP SECTION` block inside the construct is executed ONCE, by one thread of\n" ..
      "the team; which thread gets which block is unspecified, and one thread may execute\n" ..
      "several. `!$OMP END SECTIONS` closes it and carries an implicit barrier unless\n" ..
      "`NOWAIT` is present.\n" ..
      "\n" ..
      "It is the construct for a small, fixed amount of task parallelism — two or three\n" ..
      "independent phases. It scales no further than the number of sections, so for\n" ..
      "irregular or recursive work `TASK` is the better tool.\n" ..
      "\n" ..
      "The first block may follow the `SECTIONS` directive without its own `SECTION`\n" ..
      "directive; every later block needs one. `LASTPRIVATE` copies out the value from\n" ..
      "the lexically LAST section.",
    example = "!$omp parallel sections\n" ..
      "!$omp section\n" ..
      "call compute_left()\n" ..
      "!$omp section\n" ..
      "call compute_right()\n" ..
      "!$omp end parallel sections",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "SECTIONS",
    see_also = {
      "SECTION",
      "PARALLEL SECTIONS",
      "TASK",
      "NOWAIT",
    },
    signature = "!$OMP SECTIONS [clauses]",
    standard = "OpenMP 5.2",
    summary = "Worksharing: distribute a fixed set of distinct blocks across the team",
  },
  seq_cst = {
    description = "The strongest ordering. The atomic operation behaves as if it were performed in\n" ..
      "some single total order observed identically by every thread, and it implies a full\n" ..
      "memory fence before and after.\n" ..
      "\n" ..
      "It is the safe default when reasoning about a hand-written synchronisation\n" ..
      "protocol, and the most expensive: on x86 it costs a locked instruction plus a store\n" ..
      "fence, on weakly ordered architectures considerably more.\n" ..
      "\n" ..
      "`REQUIRES ATOMIC_DEFAULT_MEM_ORDER(SEQ_CST)` makes it the default for every atomic\n" ..
      "in the compilation unit.",
    example = "!$omp atomic write seq_cst\n" ..
      "flag = 1",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "SEQ_CST",
    see_also = {
      "ATOMIC",
      "FLUSH",
      "ACQ_REL",
      "RELAXED",
      "REQUIRES",
    },
    signature = "SEQ_CST",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Memory order: sequentially consistent — a full fence with a single global order",
    valid_on = {
      "ATOMIC",
      "FLUSH",
    },
  },
  shared = {
    description = "All threads see the same storage. Concurrent reads are fine; a write concurrent\n" ..
      "with any other access is a DATA RACE, and the result is undefined — not merely\n" ..
      "unpredictable — which in practice means it works in testing and fails at scale.\n" ..
      "\n" ..
      "Protect writes with `ATOMIC`, `CRITICAL`, a lock, or, for accumulation, with\n" ..
      "`REDUCTION`, which is faster than all three.\n" ..
      "\n" ..
      "Shared is the default in Fortran for everything not explicitly given another\n" ..
      "attribute, apart from loop indices and `BLOCK`-local variables. Writing\n" ..
      "`DEFAULT(NONE)` and then listing everything in `SHARED` and `PRIVATE` is the\n" ..
      "discipline that turns a race into a compile error.\n" ..
      "\n" ..
      "A shared variable is not automatically visible: memory consistency is only\n" ..
      "guaranteed at flush points (barriers, `CRITICAL`, `ATOMIC`, region boundaries).",
    example = "!$omp parallel default(none) shared(a, n) private(i)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "SHARED",
    see_also = {
      "PRIVATE",
      "DEFAULT",
      "REDUCTION",
      "ATOMIC",
    },
    signature = "SHARED(list)",
    standard = "OpenMP 5.2 §5.4.2",
    summary = "One copy of each variable, referenced by every thread in the team",
    valid_on = {
      "PARALLEL",
      "TASK",
      "TASKLOOP",
      "TEAMS",
    },
  },
  simd = {
    clauses = {
      "SAFELEN",
      "SIMDLEN",
      "LINEAR",
      "ALIGNED",
      "PRIVATE",
      "LASTPRIVATE",
      "REDUCTION",
      "COLLAPSE",
      "ORDER",
      "IF",
      "NONTEMPORAL",
    },
    description = "`SIMD` is about vector lanes, not threads: it asserts that the loop may be\n" ..
      "executed with several iterations in one vector instruction. It creates no team\n" ..
      "and no barrier, and it may appear with or without an enclosing parallel region.\n" ..
      "\n" ..
      "The assertion is yours to keep. If iteration i+1 reads a value written by\n" ..
      "iteration i, the vectorised loop gives wrong answers and nothing diagnoses it.\n" ..
      "`SAFELEN(n)` bounds the distance the compiler may assume is safe; `SIMDLEN(n)`\n" ..
      "requests a preferred vector length; `ALIGNED(list:n)` promises alignment.\n" ..
      "\n" ..
      "A variable assigned in the body must be `PRIVATE` (each lane needs its own copy);\n" ..
      "reductions need `REDUCTION`, which the compiler implements with a vector\n" ..
      "accumulator and a final horizontal combine — so floating-point results may differ\n" ..
      "from the serial order, exactly as with a threaded reduction.\n" ..
      "\n" ..
      "Introduced in OpenMP 4.0. `DO SIMD` combines it with worksharing.",
    example = "!$omp simd reduction(+:s) aligned(x, y: 64)\n" ..
      "do i = 1, n\n" ..
      "  s = s + x(i) * y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "SIMD",
    see_also = {
      "DO SIMD",
      "DECLARE SIMD",
      "SAFELEN",
      "SIMDLEN",
      "ALIGNED",
    },
    signature = "!$OMP SIMD [clauses]",
    standard = "OpenMP 5.2",
    summary = "Vectorise the following loop: iterations run in SIMD lanes of one thread",
  },
  simdlen = {
    description = "A hint, not a promise: it asks the implementation to use vectors of this many\n" ..
      "iterations. Sensible values match the hardware — 8 for double precision on AVX-512,\n" ..
      "4 on AVX2, 2 on SSE2 or NEON.\n" ..
      "\n" ..
      "On `DECLARE SIMD` it fixes the vector width of the generated function version, so\n" ..
      "callers with a different width fall back to the scalar one; naming a width there\n" ..
      "is more consequential than on a loop.\n" ..
      "\n" ..
      "Unlike `SAFELEN`, a wrong `SIMDLEN` costs performance, not correctness.",
    example = "!$omp simd simdlen(8)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "SIMDLEN",
    see_also = {
      "SIMD",
      "SAFELEN",
      "DECLARE SIMD",
      "ALIGNED",
    },
    signature = "SIMDLEN(length)",
    standard = "OpenMP 5.2",
    summary = "Preferred number of iterations to execute concurrently in SIMD lanes",
    valid_on = {
      "SIMD",
      "DO SIMD",
      "DECLARE SIMD",
    },
  },
  single = {
    clauses = {
      "PRIVATE",
      "FIRSTPRIVATE",
      "COPYPRIVATE",
      "NOWAIT",
      "ALLOCATE",
    },
    description = "Exactly one thread — not necessarily the primary thread — executes the block; the\n" ..
      "others skip it and wait at the implicit barrier of `!$OMP END SINGLE`. Use it for\n" ..
      "I/O, for one-off initialisation inside a parallel region, and as the thread that\n" ..
      "generates `TASK`s.\n" ..
      "\n" ..
      "`NOWAIT` and `COPYPRIVATE` are written on the END directive and are mutually\n" ..
      "exclusive. `COPYPRIVATE(list)` broadcasts the values the executing thread assigned\n" ..
      "to every other thread in the team, which is how a value read from a file inside\n" ..
      "the region reaches everyone without a shared variable and a barrier.\n" ..
      "\n" ..
      "`MASTER` / `MASKED` differ in two ways: they name WHICH thread runs the block, and\n" ..
      "they have NO barrier at all.",
    example = "!$omp parallel private(nthreads)\n" ..
      "!$omp single\n" ..
      "read(unit, *) nthreads\n" ..
      "!$omp end single copyprivate(nthreads)\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "SINGLE",
    see_also = {
      "MASKED",
      "MASTER",
      "COPYPRIVATE",
      "NOWAIT",
      "TASK",
    },
    signature = "!$OMP SINGLE [clauses]",
    standard = "OpenMP 5.2",
    summary = "Worksharing: the block is executed by exactly one thread of the team",
  },
  target = {
    clauses = {
      "IF",
      "DEVICE",
      "MAP",
      "PRIVATE",
      "FIRSTPRIVATE",
      "IS_DEVICE_PTR",
      "HAS_DEVICE_ADDR",
      "DEFAULTMAP",
      "NOWAIT",
      "DEPEND",
      "THREAD_LIMIT",
      "ALLOCATE",
    },
    description = "Transfers control to a device (a GPU, typically) and executes the block there. The\n" ..
      "encountering thread waits for it to finish unless `NOWAIT` makes it a deferrable\n" ..
      "target task.\n" ..
      "\n" ..
      "Data movement is the whole game. Scalars and non-pointer variables are\n" ..
      "`FIRSTPRIVATE` by default; arrays are mapped `TOFROM`, meaning they are copied to\n" ..
      "the device on entry and back on exit — for a loop called a thousand times that\n" ..
      "copying dominates everything. Hoist the data out with `TARGET DATA` or\n" ..
      "`TARGET ENTER DATA`, and then map only what changes.\n" ..
      "\n" ..
      "`TARGET` alone does not parallelise: it runs the block on ONE device thread.\n" ..
      "Parallelism comes from `TEAMS DISTRIBUTE PARALLEL DO SIMD` (or `TARGET TEAMS LOOP`\n" ..
      "in 5.x) inside it.\n" ..
      "\n" ..
      "If no device is available, or `IF` is false, the region runs on the host — so a\n" ..
      "correct offloaded code is also a correct host code, which makes incremental\n" ..
      "porting possible. gfortran needs an offload-enabled build (`-fopenmp\n" ..
      "-foffload=nvptx-none`) for any of this to leave the host.",
    example = "!$omp target teams distribute parallel do map(to: x) map(tofrom: y)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do\n" ..
      "!$omp end target teams distribute parallel do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TARGET",
    see_also = {
      "TARGET DATA",
      "TEAMS",
      "DISTRIBUTE",
      "MAP",
      "DEVICE",
    },
    signature = "!$OMP TARGET [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Execute the block on a device, mapping the named data to and from it",
  },
  target_data = {
    clauses = {
      "IF",
      "DEVICE",
      "MAP",
      "USE_DEVICE_PTR",
      "USE_DEVICE_ADDR",
    },
    description = "Creates a device data environment that spans the whole block: the mapped variables\n" ..
      "are copied according to their map types at entry and exit, and every `TARGET`\n" ..
      "region inside the block reuses that already-resident data instead of copying\n" ..
      "again.\n" ..
      "\n" ..
      "This is the first optimisation to apply to a working but slow offloaded code —\n" ..
      "wrap the time-stepping loop in `TARGET DATA`, map the fields once, and let the\n" ..
      "kernels inside map nothing.\n" ..
      "\n" ..
      "`USE_DEVICE_PTR` / `USE_DEVICE_ADDR` expose the device address of a mapped\n" ..
      "variable inside the block, which is how a mapped array is handed to a native CUDA\n" ..
      "or cuBLAS call.\n" ..
      "\n" ..
      "It is a structured block. For data whose lifetime does not nest — allocate at\n" ..
      "start-up, free at shutdown — use `TARGET ENTER DATA` and `TARGET EXIT DATA`.",
    example = "!$omp target data map(to: a) map(tofrom: u)\n" ..
      "do step = 1, nsteps\n" ..
      "  !$omp target teams distribute parallel do\n" ..
      "  do i = 2, n - 1\n" ..
      "    u(i) = u(i) + a * (u(i-1) - 2.0_dp * u(i) + u(i+1))\n" ..
      "  end do\n" ..
      "end do\n" ..
      "!$omp end target data",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TARGET DATA",
    see_also = {
      "TARGET",
      "TARGET ENTER DATA",
      "TARGET UPDATE",
      "MAP",
    },
    signature = "!$OMP TARGET DATA MAP(...) [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Create a device data environment spanning the block so nested TARGET regions reuse it",
  },
  target_enter_data = {
    clauses = {
      "MAP",
      "DEVICE",
      "IF",
      "DEPEND",
      "NOWAIT",
    },
    description = "An unstructured version of `TARGET DATA`: it maps the listed variables into the\n" ..
      "device data environment and returns, leaving them there until a matching\n" ..
      "`TARGET EXIT DATA`. Only `TO` and `ALLOC` map types are allowed.\n" ..
      "\n" ..
      "Use it when the lifetime of the device data follows an object rather than a block\n" ..
      "— allocate in a constructor, free in a destructor, map in the module's `init`\n" ..
      "routine and unmap in `finalize`.\n" ..
      "\n" ..
      "Mapping is reference-counted: mapping the same variable twice increments the\n" ..
      "count, and it leaves the device only when the count reaches zero. Unbalanced\n" ..
      "enter/exit pairs are therefore a device memory leak that no tool will report.",
    example = "!$omp target enter data map(to: a, b) map(alloc: work)\n" ..
      "call run_all_steps()\n" ..
      "!$omp target exit data map(from: b) map(delete: a, work)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TARGET ENTER DATA",
    see_also = {
      "TARGET EXIT DATA",
      "TARGET DATA",
      "MAP",
      "TARGET",
    },
    signature = "!$OMP TARGET ENTER DATA MAP(TO|ALLOC: list) [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Map data into the device data environment with an unstructured lifetime",
  },
  target_exit_data = {
    clauses = {
      "MAP",
      "DEVICE",
      "IF",
      "DEPEND",
      "NOWAIT",
    },
    description = "Ends the unstructured device lifetime started by `TARGET ENTER DATA`. `FROM`\n" ..
      "copies the values back and then releases, `RELEASE` decrements the reference count\n" ..
      "without copying, and `DELETE` removes the mapping regardless of the count.\n" ..
      "\n" ..
      "Pair every `ENTER DATA` with an `EXIT DATA` on the same variables. `DELETE` is the\n" ..
      "blunt instrument that fixes an unbalanced reference count; reaching for it usually\n" ..
      "means the enter/exit pairs are wrong somewhere else.",
    example = "!$omp target exit data map(from: result) map(release: scratch)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TARGET EXIT DATA",
    see_also = {
      "TARGET ENTER DATA",
      "TARGET DATA",
      "MAP",
    },
    signature = "!$OMP TARGET EXIT DATA MAP(FROM|RELEASE|DELETE: list) [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "End the unstructured device lifetime started by TARGET ENTER DATA",
  },
  target_update = {
    clauses = {
      "TO",
      "FROM",
      "DEVICE",
      "IF",
      "DEPEND",
      "NOWAIT",
    },
    description = "Synchronises host and device copies of already-mapped data without leaving the\n" ..
      "enclosing data environment. `FROM(list)` copies device values back to the host;\n" ..
      "`TO(list)` pushes host values out to the device.\n" ..
      "\n" ..
      "It is what makes a long-running `TARGET DATA` block practical: keep the field\n" ..
      "resident on the device for the whole time loop and pull back only the slice you\n" ..
      "want to write to disk every hundred steps.\n" ..
      "\n" ..
      "Array sections are allowed (`from: u(1:n:100)`), so only the needed part crosses\n" ..
      "the bus. The variables must already be present in the device data environment;\n" ..
      "updating something unmapped does nothing.",
    example = "!$omp target data map(tofrom: u)\n" ..
      "do step = 1, nsteps\n" ..
      "  call gpu_step(u)\n" ..
      "  if (mod(step, 100) == 0) then\n" ..
      "    !$omp target update from(u)\n" ..
      "    call write_checkpoint(u)\n" ..
      "  end if\n" ..
      "end do\n" ..
      "!$omp end target data",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TARGET UPDATE",
    see_also = {
      "TARGET DATA",
      "TARGET",
      "MAP",
      "DEVICE",
    },
    signature = "!$OMP TARGET UPDATE TO(list) | FROM(list) [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Synchronise host and device copies of already-mapped data",
  },
  task = {
    clauses = {
      "IF",
      "FINAL",
      "UNTIED",
      "DEFAULT",
      "MERGEABLE",
      "PRIVATE",
      "FIRSTPRIVATE",
      "SHARED",
      "IN_REDUCTION",
      "DEPEND",
      "PRIORITY",
      "ALLOCATE",
      "AFFINITY",
      "DETACH",
    },
    description = "Packages the block as an explicit task: a unit of work that some thread of the\n" ..
      "current team will execute at some point, not necessarily the thread that created\n" ..
      "it and not necessarily now. The generating thread continues immediately.\n" ..
      "\n" ..
      "Tasks are the tool for irregular parallelism — tree walks, recursive\n" ..
      "decomposition, while loops, work whose size is unknown — where `DO` cannot compute\n" ..
      "a trip count. The usual pattern is one `SINGLE` region generating tasks that the\n" ..
      "whole team executes.\n" ..
      "\n" ..
      "Data sharing is the trap. Inside a task, variables that were `SHARED` in the\n" ..
      "enclosing context stay shared, but everything else is FIRSTPRIVATE by default —\n" ..
      "captured by value when the task is created. A loop index passed into a task is\n" ..
      "therefore captured correctly by default, while a shared accumulator still needs\n" ..
      "`ATOMIC` or a task reduction. State a `DEFAULT(NONE)` and be explicit.\n" ..
      "\n" ..
      "Completion is not automatic: use `TASKWAIT` for the current task's children,\n" ..
      "`TASKGROUP` for all descendants, or `DEPEND` clauses to express a dependence graph\n" ..
      "the runtime schedules for you. An `UNTIED` task may migrate between threads at a\n" ..
      "scheduling point, which forbids reliance on `omp_get_thread_num` and on\n" ..
      "threadprivate state.",
    example = "!$omp parallel\n" ..
      "!$omp single\n" ..
      "do i = 1, n\n" ..
      "  !$omp task firstprivate(i) shared(a)\n" ..
      "  call solve_block(a, i)\n" ..
      "  !$omp end task\n" ..
      "end do\n" ..
      "!$omp end single\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TASK",
    see_also = {
      "TASKWAIT",
      "TASKGROUP",
      "TASKLOOP",
      "DEPEND",
      "SINGLE",
    },
    signature = "!$OMP TASK [clauses]",
    standard = "OpenMP 5.2 (introduced in 3.0)",
    summary = "Package the block as an explicit task for deferred execution by the team",
  },
  task_reduction = {
    description = "Declares the reduction on a `TASKGROUP`: private copies are created for the\n" ..
      "participating tasks and combined into the original when the taskgroup completes.\n" ..
      "Each contributing task must name the same variable and operator in an\n" ..
      "`IN_REDUCTION` clause.\n" ..
      "\n" ..
      "The operators and their identity values are those of `REDUCTION`, including\n" ..
      "user-defined ones from `DECLARE REDUCTION`.\n" ..
      "\n" ..
      "This is the only correct way to reduce across an unbounded, dynamically generated\n" ..
      "task tree; `REDUCTION` on a worksharing construct cannot see tasks.",
    example = "!$omp taskgroup task_reduction(+:nodes)\n" ..
      "call walk(root)     ! generates tasks with in_reduction(+:nodes)\n" ..
      "!$omp end taskgroup",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "TASK_REDUCTION",
    see_also = {
      "IN_REDUCTION",
      "REDUCTION",
      "TASKGROUP",
    },
    signature = "TASK_REDUCTION(operator : list)",
    standard = "OpenMP 5.2 (introduced in 5.0)",
    summary = "Open a reduction scope that tasks in the group contribute to",
    valid_on = {
      "TASKGROUP",
    },
  },
  taskgroup = {
    clauses = {
      "TASK_REDUCTION",
      "ALLOCATE",
    },
    description = "At `!$OMP END TASKGROUP` the current task waits for every task generated inside\n" ..
      "the region AND all their descendants — the whole subtree, which is what\n" ..
      "distinguishes it from `TASKWAIT`.\n" ..
      "\n" ..
      "It is also the scope of a task reduction: `TASK_REDUCTION(+:s)` on the taskgroup\n" ..
      "plus `IN_REDUCTION(+:s)` on the participating tasks gives a correct, lock-free\n" ..
      "accumulation across an arbitrary task tree.\n" ..
      "\n" ..
      "Cancellation is scoped to it too: `!$OMP CANCEL TASKGROUP` aborts the remaining\n" ..
      "tasks of the innermost enclosing taskgroup, which is how a parallel search stops\n" ..
      "once an answer is found.",
    example = "!$omp taskgroup task_reduction(+:total)\n" ..
      "do i = 1, n\n" ..
      "  !$omp task in_reduction(+:total) firstprivate(i)\n" ..
      "  total = total + weight(i)\n" ..
      "  !$omp end task\n" ..
      "end do\n" ..
      "!$omp end taskgroup",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TASKGROUP",
    see_also = {
      "TASK",
      "TASKWAIT",
      "TASK_REDUCTION",
      "IN_REDUCTION",
      "CANCEL",
    },
    signature = "!$OMP TASKGROUP [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Wait for every task generated in the region and all their descendants",
  },
  taskloop = {
    clauses = {
      "IF",
      "FINAL",
      "UNTIED",
      "DEFAULT",
      "MERGEABLE",
      "PRIVATE",
      "FIRSTPRIVATE",
      "LASTPRIVATE",
      "SHARED",
      "REDUCTION",
      "IN_REDUCTION",
      "GRAINSIZE",
      "NUM_TASKS",
      "NOGROUP",
      "PRIORITY",
      "COLLAPSE",
      "ALLOCATE",
    },
    description = "Splits the iterations of the following loop into explicit TASKS rather than\n" ..
      "dividing them among threads directly. The result composes with other tasks — a\n" ..
      "taskloop nested inside a task region participates in the same dependence graph —\n" ..
      "which a worksharing `DO` cannot do.\n" ..
      "\n" ..
      "`GRAINSIZE(n)` asks for at least n iterations per task; `NUM_TASKS(n)` asks for\n" ..
      "exactly n tasks; the two are mutually exclusive, and with neither the\n" ..
      "implementation chooses. Granularity matters more here than in a `DO` loop: each\n" ..
      "task carries real runtime overhead, so tasks of a few microseconds are a loss.\n" ..
      "\n" ..
      "The construct is implicitly wrapped in a `TASKGROUP`, so it waits for its tasks\n" ..
      "before continuing, unless `NOGROUP` is given — in which case completion must be\n" ..
      "enforced some other way.\n" ..
      "\n" ..
      "Unlike `DO`, `TASKLOOP` does not need to be inside a worksharing-free context and\n" ..
      "it does not carry a barrier; it does require an enclosing parallel region (and\n" ..
      "normally a `SINGLE`) to have threads to run on.",
    example = "!$omp parallel\n" ..
      "!$omp single\n" ..
      "!$omp taskloop grainsize(64) shared(a)\n" ..
      "do i = 1, n\n" ..
      "  call update(a, i)\n" ..
      "end do\n" ..
      "!$omp end taskloop\n" ..
      "!$omp end single\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TASKLOOP",
    see_also = {
      "TASK",
      "GRAINSIZE",
      "NUM_TASKS",
      "NOGROUP",
      "TASKGROUP",
    },
    signature = "!$OMP TASKLOOP [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.5)",
    summary = "Split the iterations of the following loop into explicit tasks",
  },
  taskwait = {
    clauses = {
      "DEPEND",
      "NOWAIT",
    },
    description = "A standalone directive: the current task waits until its CHILD tasks — the ones it\n" ..
      "generated directly — have completed. It does NOT wait for grandchildren; for the\n" ..
      "whole subtree use `TASKGROUP`.\n" ..
      "\n" ..
      "This is the synchronisation point of recursive task parallelism: spawn the\n" ..
      "subproblems, `TASKWAIT`, then combine. Forgetting it means reading results that do\n" ..
      "not exist yet, and the symptom is intermittent wrong answers rather than a hang.\n" ..
      "\n" ..
      "Since OpenMP 5.0 a `DEPEND` clause makes the wait selective: it waits only for the\n" ..
      "child tasks whose dependences match, which avoids serialising on unrelated work.",
    example = "!$omp task shared(l)\n" ..
      "call solve(l)\n" ..
      "!$omp end task\n" ..
      "!$omp task shared(r)\n" ..
      "call solve(r)\n" ..
      "!$omp end task\n" ..
      "!$omp taskwait\n" ..
      "call combine(l, r)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TASKWAIT",
    see_also = {
      "TASK",
      "TASKGROUP",
      "DEPEND",
      "BARRIER",
    },
    signature = "!$OMP TASKWAIT [DEPEND(...)]",
    standard = "OpenMP 5.2 (introduced in 3.0)",
    summary = "Wait for the tasks generated directly by the current task",
  },
  taskyield = {
    clauses = {},
    description = "A standalone directive marking a point at which the current task MAY be suspended\n" ..
      "so the thread can run another task. It is a hint: the implementation is free to do\n" ..
      "nothing.\n" ..
      "\n" ..
      "Its use is inside a long spin or a wait loop in a task, where blocking the thread\n" ..
      "would starve the rest of the task graph. It is not a synchronisation point and\n" ..
      "guarantees nothing about progress.",
    example = "do while (.not. ready)\n" ..
      "  !$omp taskyield\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TASKYIELD",
    see_also = {
      "TASK",
      "TASKWAIT",
      "UNTIED",
    },
    signature = "!$OMP TASKYIELD",
    standard = "OpenMP 5.2 (introduced in 3.1)",
    summary = "Mark a point at which the current task may be suspended so the thread can run another",
  },
  teams = {
    clauses = {
      "NUM_TEAMS",
      "THREAD_LIMIT",
      "DEFAULT",
      "PRIVATE",
      "FIRSTPRIVATE",
      "SHARED",
      "REDUCTION",
      "ALLOCATE",
    },
    description = "Creates a LEAGUE of thread teams, each with its own primary thread, all executing\n" ..
      "the block. It maps onto a GPU's independently scheduled blocks: `NUM_TEAMS` is the\n" ..
      "grid size and `THREAD_LIMIT` bounds the threads per team.\n" ..
      "\n" ..
      "There is no synchronisation between teams — no barrier, no ordering, no shared\n" ..
      "locks that would be safe — so the only construct that spreads work ACROSS teams is\n" ..
      "`DISTRIBUTE`. Inside a team, the usual `PARALLEL DO` and `SIMD` apply, which is why\n" ..
      "the canonical offload loop reads `TARGET TEAMS DISTRIBUTE PARALLEL DO SIMD`.\n" ..
      "\n" ..
      "Until OpenMP 5.0 a `TEAMS` region had to be strictly nested inside `TARGET`; since\n" ..
      "5.0 it may also appear on the host, where it is usually pointless.",
    example = "!$omp target teams distribute parallel do num_teams(128) thread_limit(256)\n" ..
      "do i = 1, n\n" ..
      "  y(i) = a * x(i) + y(i)\n" ..
      "end do",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "TEAMS",
    see_also = {
      "TARGET",
      "DISTRIBUTE",
      "NUM_TEAMS",
      "THREAD_LIMIT",
      "LOOP",
    },
    signature = "!$OMP TEAMS [clauses]",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Create a league of thread teams, each executing the block",
  },
  thread_limit = {
    description = "Caps the threads available to each team — on a GPU, the block size. A `NUM_THREADS`\n" ..
      "clause inside the region cannot exceed it, and `omp_get_thread_limit()` reports the\n" ..
      "value in force.\n" ..
      "\n" ..
      "On `TARGET` (allowed there since OpenMP 5.1) it bounds the threads in the initial\n" ..
      "team on the device.\n" ..
      "\n" ..
      "Powers of two that match the device's warp or wavefront size (128, 256) are the\n" ..
      "usual choices; too large a limit wastes registers per thread and reduces occupancy.",
    example = "!$omp target teams thread_limit(256)",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "THREAD_LIMIT",
    see_also = {
      "TEAMS",
      "NUM_TEAMS",
      "NUM_THREADS",
      "omp_get_thread_limit",
    },
    signature = "THREAD_LIMIT(scalar-integer-expr)",
    standard = "OpenMP 5.2 (introduced in 4.0)",
    summary = "Upper bound on the number of threads in each team of the region",
    valid_on = {
      "TEAMS",
      "TARGET",
      "TARGET TEAMS",
    },
  },
  threadprivate = {
    clauses = {},
    description = "A declarative directive, written in the specification part immediately after the\n" ..
      "declaration of the listed variables (or common blocks, spelled\n" ..
      "`!$OMP THREADPRIVATE(/blockname/)`). Each thread gets a private copy that lives for\n" ..
      "the whole program, not just one region — that is the difference from the `PRIVATE`\n" ..
      "clause.\n" ..
      "\n" ..
      "Only variables with static storage qualify: module variables, `save`d locals, and\n" ..
      "common blocks. Every program unit that declares a threadprivate common block must\n" ..
      "give the same directive, or the program is invalid in a way no compiler checks.\n" ..
      "\n" ..
      "Values PERSIST between parallel regions only if the regions have the same number of\n" ..
      "threads, dynamic thread adjustment is disabled (`omp_set_dynamic(.false.)`), and\n" ..
      "neither region is nested — otherwise the copies are undefined on entry.\n" ..
      "\n" ..
      "The primary thread's copy is the original variable and is the one the serial parts\n" ..
      "of the program see; `COPYIN(list)` on a `PARALLEL` directive broadcasts that value\n" ..
      "to the other threads at region entry.",
    example = "module counters\n" ..
      "  integer :: hits = 0\n" ..
      "  !$omp threadprivate(hits)\n" ..
      "end module",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "THREADPRIVATE",
    see_also = {
      "COPYIN",
      "PRIVATE",
      "save",
      "common",
    },
    signature = "!$OMP THREADPRIVATE(list)",
    standard = "OpenMP 5.2 §5.2",
    summary = "Give each thread its own persistent copy of a module, saved or common variable",
  },
  untied = {
    description = "By default a task is TIED: once a thread starts it, only that thread may resume it\n" ..
      "after a suspension. `UNTIED` lifts that, which improves load balance for tasks that\n" ..
      "suspend often (at `TASKWAIT`, `TASKYIELD` or a nested taskgroup).\n" ..
      "\n" ..
      "The price: an untied task may not rely on anything thread-specific.\n" ..
      "`omp_get_thread_num()` may return a different value before and after a suspension,\n" ..
      "threadprivate variables may change identity, and a lock acquired on one thread and\n" ..
      "released on another is invalid. In practice, use untied only for tasks whose body\n" ..
      "is pure computation over its own data.",
    example = "!$omp task untied\n" ..
      "call deep_recursive_work(node)\n" ..
      "!$omp end task",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "UNTIED",
    see_also = {
      "TASK",
      "MERGEABLE",
      "FINAL",
      "TASKYIELD",
    },
    signature = "UNTIED",
    standard = "OpenMP 5.2",
    summary = "Allow a suspended task to be resumed by a different thread",
    valid_on = {
      "TASK",
      "TASKLOOP",
    },
  },
  update = {
    description = "The implicit form of `!$OMP ATOMIC`. It applies to `x = x op expr` or\n" ..
      "`x = intrinsic(x, expr)`, where `op` is one of `+ - * / .and. .or. .eqv. .neqv.`\n" ..
      "and the intrinsic is `max`, `min`, `iand`, `ior` or `ieor`. `x` must appear exactly\n" ..
      "once, as an operand and not inside the expression.\n" ..
      "\n" ..
      "Only the update of `x` is atomic; `expr` is evaluated without protection, so a\n" ..
      "function call in it may run concurrently on many threads.\n" ..
      "\n" ..
      "The same keyword is also a `DEPOBJ` clause, where it changes the dependence type\n" ..
      "stored in a dependence object.",
    example = "!$omp atomic update\n" ..
      "total = total + contribution",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "UPDATE",
    see_also = {
      "ATOMIC",
      "READ",
      "WRITE",
      "CAPTURE",
      "REDUCTION",
    },
    signature = "UPDATE",
    standard = "OpenMP 5.2",
    summary = "ATOMIC form (the default): make a read-modify-write indivisible",
    valid_on = {
      "ATOMIC",
      "DEPOBJ",
    },
  },
  workshare = {
    clauses = {
      "NOWAIT",
    },
    description = "`WORKSHARE` divides the work of Fortran ARRAY SYNTAX — whole-array assignments,\n" ..
      "`WHERE`, `FORALL`, and array intrinsics such as `matmul`, `sum`, `dot_product` —\n" ..
      "into units and distributes them across the team. It exists because those\n" ..
      "statements have no loop for a `DO` directive to attach to.\n" ..
      "\n" ..
      "Only a restricted set of statements may appear in the block: array and scalar\n" ..
      "assignments, `WHERE`, `FORALL`, `ATOMIC`, `CRITICAL` and `PARALLEL` constructs.\n" ..
      "Anything else, including a procedure call that is not `ELEMENTAL`, is not allowed.\n" ..
      "\n" ..
      "The result is as if the statements were executed in order, so there is no need to\n" ..
      "worry about dependences between successive assignments — but that also means the\n" ..
      "implementation may serialise more than you hope. Compiler quality varies widely;\n" ..
      "gfortran's implementation is simple, and an explicit `!$OMP DO` over an equivalent\n" ..
      "loop is usually faster and always more predictable.\n" ..
      "\n" ..
      "`!$OMP END WORKSHARE` is required and has an implicit barrier unless `NOWAIT` is\n" ..
      "given.",
    example = "!$omp parallel\n" ..
      "!$omp workshare\n" ..
      "a = b + c\n" ..
      "where (a > 0.0_dp) a = sqrt(a)\n" ..
      "!$omp end workshare\n" ..
      "!$omp end parallel",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "directive",
    module = "OpenMP 5.2",
    name = "WORKSHARE",
    see_also = {
      "PARALLEL WORKSHARE",
      "DO",
      "NOWAIT",
    },
    signature = "!$OMP WORKSHARE [clauses]",
    standard = "OpenMP 5.2",
    summary = "Fortran-only worksharing: divide array syntax statements among the team",
  },
  write = {
    description = "`!$OMP ATOMIC WRITE` applies to `x = expr`: the expression is evaluated without\n" ..
      "protection, the STORE to `x` is indivisible. Other threads see either the old value\n" ..
      "or the new one, never a partial write.\n" ..
      "\n" ..
      "Combine with `RELEASE` or `SEQ_CST` to publish data written before it.",
    example = "!$omp atomic write\n" ..
      "ready = 1",
    href = "https://www.openmp.org/spec-html/5.2/openmp.html",
    kind = "clause",
    module = "OpenMP 5.2",
    name = "WRITE",
    see_also = {
      "ATOMIC",
      "READ",
      "UPDATE",
      "CAPTURE",
      "RELEASE",
    },
    signature = "WRITE",
    standard = "OpenMP 5.2",
    summary = "ATOMIC form: make a single store to a memory location indivisible",
    valid_on = {
      "ATOMIC",
    },
  },
}
