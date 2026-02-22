# YAML Configuration Reference

## Complete Frontmatter Schema

```yaml
---
# REQUIRED FIELDS
name: skill-name                      # Skill identifier
description: What and when to use     # Trigger description

# OPTIONAL FIELDS
license: Apache-2.0                   # License identifier
compatibility: Requires Python 3.8+  # Environment requirements

# Tool Control
allowed-tools: Read, Grep, Glob      # Comma-separated
allowed-tools:                        # Or YAML list
  - Read
  - Bash(python:*)
  - Write

# Execution Context
model: claude-sonnet-4-20250514      # Specific model
context: fork                         # Run in isolated subagent
agent: general-purpose               # Agent type when forked

# Visibility Control
user-invocable: true                 # Show in /slash menu
disable-model-invocation: false      # Block programmatic use

# Custom Metadata
metadata:
  author: your-name
  version: "1.0"
  tags:
    - development
    - testing

# Lifecycle Hooks
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "./scripts/lint.sh"
  Stop:
    - hooks:
        - type: prompt
          prompt: "Verify all tasks complete"
---
```

## Field Specifications

### name (Required)

**Purpose**: Unique identifier for the skill.

**Constraints**:
- Lowercase letters, numbers, hyphens only
- Maximum 64 characters
- Must match directory name
- No spaces or underscores

**Examples**:
```yaml
# Good
name: pdf-processing
name: commit-helper
name: webapp-testing-v2

# Bad
name: PDF Processing      # Uppercase, spaces
name: commit_helper       # Underscore
name: my-very-long-skill-name-that-exceeds-sixty-four-characters-limit
```

### description (Required)

**Purpose**: Claude uses this for semantic matching to decide when to apply the skill.

**Constraints**:
- Maximum 1024 characters
- No XML tags allowed
- Should include what AND when

**Formula**: `[What it does] + [When to use it] + [Trigger keywords]`

**Examples**:
```yaml
# Good - Specific, trigger-rich
description: >
  Extract text and tables from PDF files, fill forms, merge documents.
  Use when working with PDF files or when the user mentions PDFs,
  forms, or document extraction.

# Bad - Vague
description: Helps with files
```

### license (Optional)

**Purpose**: Specify licensing for shared skills.

**Common Values**:
- `Apache-2.0`
- `MIT`
- `BSD-3-Clause`
- `proprietary`

### compatibility (Optional)

**Purpose**: Document environment requirements.

**Constraints**: Maximum 500 characters.

**Examples**:
```yaml
compatibility: Requires Python 3.8+ with pandas and openpyxl
compatibility: Node.js 18+ required for script execution
compatibility: Works on macOS and Linux only
```

### allowed-tools (Optional)

**Purpose**: Restrict which tools Claude can use without asking permission.

**Behavior**:
- When specified, only listed tools are allowed
- When omitted, no restrictions apply
- Supports glob patterns for Bash commands

**Formats**:
```yaml
# Comma-separated string
allowed-tools: Read, Grep, Glob, Bash(python:*)

# YAML list
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash(python:*)
  - Bash(npm:*)

# Bash patterns
allowed-tools:
  - Bash(python:*)      # Any python command
  - Bash(npm run:*)     # Any npm run command
  - Bash(git status)    # Exact command only
```

**Common Tool Sets**:

| Use Case | Tools |
|----------|-------|
| Read-only analysis | `Read, Grep, Glob` |
| Python scripting | `Read, Write, Bash(python:*)` |
| Full development | (omit field - no restrictions) |

### model (Optional)

**Purpose**: Use a specific model when the skill is active.

**Values**:
```yaml
model: claude-sonnet-4-20250514
model: claude-opus-4-20250514
```

**Use Cases**:
- Complex reasoning: Use opus
- Fast iteration: Use sonnet
- Cost optimization: Use appropriate model

### context (Optional)

**Purpose**: Run skill in isolated subagent context.

**Value**: `fork`

**Behavior**:
- Skill runs in separate conversation context
- Results returned to main conversation
- Useful for exploration without polluting main context

```yaml
context: fork
agent: general-purpose
```

### agent (Optional)

**Purpose**: Specify agent type when `context: fork` is set.

**Values**:
- `general-purpose` - Full capabilities
- `Explore` - Optimized for codebase exploration
- `Plan` - Optimized for planning
- `[custom-agent-name]` - Custom defined agent

### user-invocable (Optional)

**Purpose**: Control visibility in /slash command menu.

**Default**: `true`

**Behavior**:
| Value | Slash Menu | Programmatic | Auto-discovery |
|-------|------------|--------------|----------------|
| `true` | Visible | Allowed | Yes |
| `false` | Hidden | Allowed | Yes |

**Use Case for `false`**: Skills Claude should use automatically but users shouldn't invoke directly.

### disable-model-invocation (Optional)

**Purpose**: Prevent Claude from invoking the skill programmatically.

**Default**: `false`

**Behavior**:
| Value | Slash Menu | Programmatic | Auto-discovery |
|-------|------------|--------------|----------------|
| `true` | Visible | Blocked | Yes |
| `false` | Visible | Allowed | Yes |

**Use Case**: Skills users should invoke manually, not Claude automatically.

### metadata (Optional)

**Purpose**: Store arbitrary key-value pairs for documentation or tooling.

**Examples**:
```yaml
metadata:
  author: team-name
  version: "2.1.0"
  created: "2025-01-15"
  tags:
    - development
    - testing
    - automation
  dependencies:
    - python>=3.8
    - pandas
```

### hooks (Optional)

**Purpose**: Run commands or prompts at skill lifecycle events.

**Events**:
- `PreToolUse`: Before a tool executes
- `PostToolUse`: After a tool completes
- `Stop`: When skill finishes responding

**Hook Types**:
- `command`: Execute shell command
- `prompt`: Inject prompt into conversation

**Structure**:
```yaml
hooks:
  PreToolUse:
    - matcher: "ToolName"           # Regex pattern
      hooks:
        - type: command
          command: "./script.sh"
          once: true                # Run only once per session
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "./lint.sh"
  Stop:
    - hooks:
        - type: prompt
          prompt: "Verify completion"
```

**Variables Available**:
- `$TOOL_INPUT`: Input provided to the tool
- `$TOOL_OUTPUT`: Output from the tool (PostToolUse only)
- `$CLAUDE_PROJECT_DIR`: Project root directory
- `$CLAUDE_SESSION_ID`: Current session identifier

## String Substitutions

Skills support dynamic variable substitution:

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | Arguments passed when invoking skill |
| `${CLAUDE_SESSION_ID}` | Current session ID |
| `$CLAUDE_PROJECT_DIR` | Project root directory |

**Usage in Content**:
```markdown
## Session Information
Current session: ${CLAUDE_SESSION_ID}
Project root: $CLAUDE_PROJECT_DIR

## Using Arguments
The user requested: $ARGUMENTS
```

## Validation Rules

### YAML Syntax
- Frontmatter must start with `---` on line 1
- No blank lines before frontmatter
- Use spaces for indentation (not tabs)
- Close frontmatter with `---`

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Skill not loading | Blank line before `---` | Remove blank lines |
| Invalid name | Contains spaces/uppercase | Use lowercase-kebab-case |
| Description too long | Over 1024 chars | Shorten description |
| Tools not working | Invalid tool name | Check exact tool names |

### Debugging

Run Claude Code with debug flag:
```bash
claude --debug
```

Check skill discovery:
```bash
ls -la ~/.claude/skills/
ls -la .claude/skills/
```
