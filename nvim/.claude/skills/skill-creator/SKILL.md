---
name: skill-creator
description: Guide for creating effective Claude Code skills with best practices. Use when users want to create a new skill, update an existing skill, learn skill authoring patterns, or design reusable prompt architectures. Covers file structure, YAML configuration, progressive disclosure, subagent orchestration, and validation workflows.
---

# Claude Code Skill Creator

## Overview

This skill guides the creation of high-quality, reusable Claude Code skills. Skills are specialized knowledge packages that extend Claude's capabilities for domain-specific tasks. They are automatically discovered and applied based on context.

## When to Create a Skill

Create a skill when you observe:
- **Repeated prompts**: The same instructions typed across multiple conversations
- **Domain expertise**: Specialized knowledge that fills genuine gaps in Claude's training
- **Team conventions**: Project-specific workflows, coding standards, or processes
- **Tool orchestration**: Complex multi-tool workflows requiring coordination

## Workflow Phases

### Phase 1: Research & Analysis

Before writing any skill content, spawn subagents to gather context:

```
Task: Research phase - spawn in parallel:
1. Explore agent: Analyze existing skills in ~/.claude/skills/ and .claude/skills/
2. Explore agent: Search codebase for patterns related to the skill domain
3. General-purpose agent: Fetch relevant documentation from web sources
4. General-purpose agent: Review anthropics/skills repo for similar examples
```

**Key questions to answer:**
- What problem does this skill solve?
- What triggers should activate it?
- What tools will it need?
- What existing patterns can be reused?

### Phase 2: Design & Planning

Create a plan file before implementation:

```markdown
# Skill Design: [skill-name]

## Problem Statement
[What gap does this fill?]

## Trigger Conditions
[When should Claude activate this skill?]

## Tool Requirements
[Which tools needed? Any restrictions?]

## File Structure
[What files will be created?]

## Progressive Disclosure Strategy
[What loads immediately vs. on-demand?]
```

### Phase 3: Implementation

Follow the structure in [references/file-structure.md](references/file-structure.md).

**Implementation order:**
1. Create directory: `.claude/skills/[skill-name]/`
2. Write SKILL.md with frontmatter and core instructions
3. Add reference files for detailed documentation
4. Create templates for common patterns
5. Add scripts for executable workflows

### Phase 4: Validation & Testing

Use the checklist in [references/validation-checklist.md](references/validation-checklist.md).

Test the skill by:
1. Starting a new Claude Code session
2. Asking a question that should trigger the skill
3. Verifying Claude asks to use the skill
4. Confirming instructions are followed correctly

---

## Core Principles

### 1. Context Window is a Public Good

Every token in a skill competes with conversation history. Apply these rules:

| Include | Exclude |
|---------|---------|
| Domain-specific knowledge Claude lacks | General programming knowledge |
| Project conventions and patterns | Standard library documentation |
| Trigger-specific workflows | Information available via web search |
| Anti-patterns to avoid | Verbose explanations of basics |

### 2. Progressive Disclosure Architecture

Skills load in three stages:

```
Stage 1: Metadata (~100 tokens)
├── name + description only
└── Always loaded at startup

Stage 2: Instructions (<5000 tokens)
├── SKILL.md body
└── Loaded when skill activates

Stage 3: Resources (on-demand)
├── references/*.md
├── templates/*
└── Loaded only when referenced
```

**Rule**: Keep SKILL.md under 500 lines. Move detailed content to `references/`.

### 3. Freedom Levels

Match instruction specificity to task fragility:

| Freedom Level | Use Case | Format |
|---------------|----------|--------|
| High | Creative, exploratory tasks | Open guidance, principles |
| Medium | Preferred patterns exist | Pseudocode, parameterized scripts |
| Low | Fragile operations | Exact scripts, strict workflows |

---

## YAML Frontmatter Reference

### Required Fields

```yaml
---
name: skill-name              # lowercase, hyphens, max 64 chars
description: What and when    # max 1024 chars, no XML tags
---
```

### Optional Fields

```yaml
---
name: example-skill
description: Description here
license: Apache-2.0                    # License identifier
compatibility: Requires Python 3.8+    # Max 500 chars
allowed-tools: Read, Grep, Glob        # Tool restrictions
allowed-tools:                         # Or as YAML list
  - Read
  - Bash(python:*)
model: claude-sonnet-4-20250514        # Specific model
context: fork                          # Isolated subagent
agent: general-purpose                 # Agent type when forked
user-invocable: true                   # Show in slash menu
disable-model-invocation: false        # Block programmatic use
metadata:                              # Arbitrary key-value pairs
  author: your-name
  version: "1.0"
hooks:                                 # Lifecycle hooks
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
---
```

See [references/configuration.md](references/configuration.md) for detailed options.

---

## Writing Effective Descriptions

The description is **critical** - Claude uses semantic matching to decide when to apply skills.

### Description Formula

```
[What it does] + [When to use it] + [Trigger keywords]
```

### Examples

| Quality | Description |
|---------|-------------|
| Bad | "Helps with documents" |
| Good | "Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction." |

| Quality | Description |
|---------|-------------|
| Bad | "Data analysis skill" |
| Good | "Analyze sales data in Excel files and CRM exports. Use when working with .xlsx files, pivot tables, or generating sales reports from structured data." |

### Trigger Term Strategy

Include keywords users naturally say:
- File extensions: `.pdf`, `.xlsx`, `.docx`
- Action verbs: "extract", "generate", "convert", "analyze"
- Domain terms: "API", "database", "deployment", "testing"
- Tool names: "Playwright", "pandas", "Docker"

---

## Subagent Orchestration

### When to Spawn Subagents

Spawn subagents for:
- **Parallel research**: Multiple independent information gathering tasks
- **Context isolation**: Exploration that shouldn't pollute main context
- **Specialized work**: Tasks requiring different tool sets
- **Verification**: Independent validation of outputs

### Subagent Patterns

```markdown
## Research Phase (Parallel)
Spawn these subagents simultaneously:
1. Explore agent: [specific exploration task]
2. General-purpose agent: [web research task]
3. Explore agent: [codebase analysis task]

## Implementation Phase (Sequential or Parallel)
For independent files, spawn parallel implementation agents:
1. General-purpose agent: Implement [component A]
2. General-purpose agent: Implement [component B]

## Validation Phase
Spawn verification agent to review all outputs.
```

### Subagent Best Practices

1. **One clear goal per subagent** - Single input, single output, single handoff
2. **Action-oriented descriptions** - "Analyze X and produce Y"
3. **Scope tools narrowly** - 5 focused tools > 50 generic tools
4. **Use resume for continuation** - Preserve context across interactions

### Limitations

- Subagents cannot spawn other subagents
- Results return to main context only
- For nested delegation, chain from main conversation

---

## File Structure Patterns

### Minimal Skill

```
my-skill/
└── SKILL.md
```

### Standard Skill

```
my-skill/
├── SKILL.md           # Core instructions (<500 lines)
├── references/
│   ├── api.md         # Detailed API documentation
│   ├── examples.md    # Usage examples
│   └── troubleshooting.md
└── templates/
    └── starter.md     # Template for common outputs
```

### Complex Skill

```
my-skill/
├── SKILL.md
├── references/
│   ├── architecture.md
│   ├── api-reference.md
│   ├── best-practices.md
│   └── anti-patterns.md
├── templates/
│   ├── basic.md
│   ├── advanced.md
│   └── checklist.md
└── scripts/
    ├── validate.py
    ├── generate.sh
    └── test.py
```

See [templates/skill-template.md](templates/skill-template.md) for starter template.

---

## Anti-Patterns to Avoid

### Content Anti-Patterns

- **Verbose basics**: Don't explain what Claude already knows
- **Redundant documentation**: Don't duplicate official docs
- **Over-specification**: Don't constrain unnecessarily
- **Missing triggers**: Vague descriptions that never match

### Structure Anti-Patterns

- **Monolithic SKILL.md**: Files over 500 lines hurt performance
- **Deep nesting**: Keep references one level deep
- **Missing validation**: No way to verify skill works correctly
- **Hardcoded paths**: Use relative paths from skill root

### Process Anti-Patterns

- **No research phase**: Writing skills without understanding context
- **No iteration**: Not observing how Claude actually uses the skill
- **No testing**: Deploying without verification

---

## Quick Reference

### Skill Locations

| Location | Path | Scope |
|----------|------|-------|
| Personal | `~/.claude/skills/` | All your projects |
| Project | `.claude/skills/` | This repository only |

### Validation Commands

```bash
# Check skill structure
ls -la .claude/skills/[skill-name]/

# Verify YAML syntax (no blank lines before frontmatter)
head -5 .claude/skills/[skill-name]/SKILL.md

# Test skill discovery
claude --debug
```

### Specification Compliance

| Requirement | Rule |
|-------------|------|
| name | Lowercase, hyphens, max 64 chars |
| description | Max 1024 chars, no XML tags |
| SKILL.md | Under 500 lines recommended |
| Paths | Unix-style forward slashes |
| References | One level deep from SKILL.md |

---

## Additional Resources

- [references/file-structure.md](references/file-structure.md) - Detailed file organization
- [references/configuration.md](references/configuration.md) - All YAML options explained
- [references/validation-checklist.md](references/validation-checklist.md) - Pre-deployment checklist
- [references/subagent-patterns.md](references/subagent-patterns.md) - Advanced orchestration
- [templates/skill-template.md](templates/skill-template.md) - Starter template
- [templates/description-examples.md](templates/description-examples.md) - Description patterns

## External Documentation

- Official Skills Docs: https://code.claude.com/docs/en/skills
- Skills Repository: https://github.com/anthropics/skills
- Skills Specification: https://agentskills.io
