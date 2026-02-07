# Subagent Orchestration Patterns

## Core Principles

### 1. One Goal Per Subagent

Each subagent should have:
- **One input**: Clear task description
- **One output**: Specific deliverable
- **One handoff rule**: When to return results

**Good**:
```
Explore agent: Search for all files containing "authentication"
and return a summary of the authentication architecture.
```

**Bad**:
```
Agent: Look at authentication, then fix bugs, then write tests,
then update docs.
```

### 2. Action-Oriented Descriptions

Write descriptions that specify the action and output:

| Bad | Good |
|-----|------|
| "Research authentication" | "Analyze authentication flow and list all entry points" |
| "Look at the codebase" | "Map file structure and identify key modules" |
| "Help with testing" | "Run test suite and report failures with stack traces" |

### 3. Narrow Tool Scope

Subagents perform better with focused tool sets:

| Task Type | Recommended Tools |
|-----------|------------------|
| Research/Exploration | `Read, Grep, Glob` |
| Web Research | `WebFetch, WebSearch, Read` |
| Implementation | `Read, Write, Edit, Bash` |
| Validation | `Read, Bash, Grep` |

---

## Parallel Research Pattern

Use for gathering independent information simultaneously.

```markdown
## Research Phase

Spawn these subagents in parallel:

1. **Explore agent**: Analyze existing codebase structure
   - Search for patterns matching [domain]
   - Return: File map and key components

2. **General-purpose agent**: Fetch external documentation
   - URL: [documentation URL]
   - Return: Relevant sections summarized

3. **Explore agent**: Find existing implementations
   - Search for similar functionality
   - Return: Code patterns and conventions used

4. **General-purpose agent**: Web search for best practices
   - Query: "[topic] best practices 2025"
   - Return: Key recommendations with sources
```

### When to Use

- Starting a new task requiring context
- Multiple independent information sources
- Time-sensitive research (parallel = faster)

### Implementation

```
Task tool calls (parallel):
├── Explore: "Analyze codebase for [X]"
├── General-purpose: "Fetch and summarize [URL]"
├── Explore: "Find implementations of [Y]"
└── General-purpose: "Search web for [Z] best practices"
```

---

## Sequential Pipeline Pattern

Use for tasks with dependencies between stages.

```markdown
## Pipeline Stages

### Stage 1: Specification (PM Agent)
- Input: User requirements
- Process: Clarify scope, write spec
- Output: Specification document
- Handoff: When spec is marked READY_FOR_ARCH

### Stage 2: Architecture (Architect Agent)
- Input: Specification from Stage 1
- Process: Design system, create ADR
- Output: Architecture Decision Record
- Handoff: When design is marked READY_FOR_BUILD

### Stage 3: Implementation (Builder Agent)
- Input: ADR from Stage 2
- Process: Write code, tests
- Output: Working implementation
- Handoff: When tests pass
```

### When to Use

- Complex multi-phase projects
- Tasks requiring sign-off between stages
- Work that builds on previous outputs

### Status Tracking

Use explicit status markers:
```
READY_FOR_SPEC → READY_FOR_ARCH → READY_FOR_BUILD → DONE
```

---

## Parallel Implementation Pattern

Use for implementing independent components simultaneously.

```markdown
## Implementation Phase

After planning is complete, spawn parallel implementation agents:

1. **General-purpose agent**: Implement Component A
   - File: src/components/a.ts
   - Requirements: [from plan]
   - Tests: src/components/a.test.ts

2. **General-purpose agent**: Implement Component B
   - File: src/components/b.ts
   - Requirements: [from plan]
   - Tests: src/components/b.test.ts

3. **General-purpose agent**: Implement Component C
   - File: src/components/c.ts
   - Requirements: [from plan]
   - Tests: src/components/c.test.ts

## Integration Phase (Sequential)

After all implementations complete:
4. **General-purpose agent**: Integrate components
   - Combine A, B, C
   - Run integration tests
```

### When to Use

- Multiple independent files/modules
- Components with clear boundaries
- No shared state during implementation

### Important Constraints

- Files must be independent (no edit conflicts)
- Each agent works on distinct files
- Integration happens after parallel work

---

## Verification Pattern

Use for independent validation of work.

```markdown
## Verification Phase

Spawn verification agent after implementation:

**General-purpose agent**: Verify implementation
- Review: All files changed in implementation
- Check: Requirements from specification
- Validate:
  - Code follows project conventions
  - Tests exist and pass
  - No security issues
  - Documentation updated
- Output: Verification report with pass/fail
```

### Verification Checklist Template

```markdown
## Verification Report

### Requirements Coverage
- [ ] Requirement 1: [status]
- [ ] Requirement 2: [status]

### Code Quality
- [ ] Follows project conventions
- [ ] No linting errors
- [ ] No type errors

### Testing
- [ ] Unit tests exist
- [ ] Tests pass
- [ ] Coverage adequate

### Security
- [ ] No hardcoded secrets
- [ ] Input validation present
- [ ] No injection vulnerabilities

### Documentation
- [ ] Code comments where needed
- [ ] API documentation updated
- [ ] README updated if needed
```

---

## Context Preservation Pattern

Use resume capability for long-running tasks.

```markdown
## Long Task Handling

When a subagent task may be interrupted:

1. **Initial spawn**: Start the agent with clear checkpoint instructions
2. **Checkpoint outputs**: Agent writes progress to files
3. **Resume if needed**: Use agent ID to continue

### Checkpoint Strategy

Agent should write intermediate results:
- `progress.md`: Current status
- `findings.md`: Accumulated results
- `next-steps.md`: Remaining work
```

### Resume Syntax

```
Task tool with resume parameter:
- resume: [agent-id-from-previous-run]
- prompt: "Continue from where you left off"
```

---

## Subagent Tool Scoping

### Read-Only Research

```yaml
# Subagent for exploration
tools:
  - Read
  - Grep
  - Glob
  - WebFetch
  - WebSearch
```

### Safe Analysis

```yaml
# Subagent for code analysis
tools:
  - Read
  - Grep
  - Glob
  - Bash(read-only commands)
```

### Full Implementation

```yaml
# Subagent for building
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
```

---

## Anti-Patterns

### Don't: Spawn Subagent for Simple Tasks

```markdown
# Bad - Overkill
Spawn agent to: "Read the README.md file"

# Good - Direct tool use
Use Read tool on README.md
```

### Don't: Chain Subagent Spawning

```markdown
# Bad - Subagents can't spawn subagents
Agent A spawns Agent B which spawns Agent C

# Good - Orchestrate from main context
Main context spawns A, waits, spawns B, waits, spawns C
```

### Don't: Vague Task Descriptions

```markdown
# Bad
"Look into the authentication system"

# Good
"Map all authentication endpoints in src/auth/,
list middleware used, identify token validation logic,
return structured summary"
```

### Don't: Overlapping File Access

```markdown
# Bad - Edit conflict risk
Agent A: Edit src/index.ts
Agent B: Edit src/index.ts

# Good - Separate files
Agent A: Edit src/auth.ts
Agent B: Edit src/db.ts
```

---

## Decision Matrix

| Scenario | Pattern | Parallel? |
|----------|---------|-----------|
| Multiple info sources | Research | Yes |
| Phased workflow | Pipeline | No |
| Independent modules | Implementation | Yes |
| Quality assurance | Verification | After work |
| Complex/interruptible | Preservation | N/A |

---

## Example: Full Skill Creation Workflow

```markdown
## Phase 1: Research (Parallel)

Spawn simultaneously:
1. Explore: Analyze existing skills in repo
2. General-purpose: Fetch official skill docs
3. General-purpose: Search for skill best practices
4. Explore: Find similar implementations

## Phase 2: Design (Sequential)

Spawn:
5. Plan agent: Design skill structure based on research

## Phase 3: Implementation (Parallel)

Spawn simultaneously:
6. General-purpose: Write SKILL.md
7. General-purpose: Write reference files
8. General-purpose: Write templates

## Phase 4: Validation (Sequential)

Spawn:
9. General-purpose: Validate against checklist
```
