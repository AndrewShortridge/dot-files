# Skill File Structure Reference

## Directory Hierarchy

```
skill-name/                     # Directory name should match skill name
├── SKILL.md                    # REQUIRED: Entry point, <500 lines
├── references/                 # Optional: Detailed documentation
│   ├── api.md                  # API reference, loaded on-demand
│   ├── examples.md             # Usage examples
│   ├── troubleshooting.md      # Common issues and solutions
│   └── best-practices.md       # Domain-specific guidelines
├── templates/                  # Optional: Reusable content patterns
│   ├── starter.md              # Basic template
│   ├── advanced.md             # Full-featured template
│   └── checklist.md            # Validation checklist
└── scripts/                    # Optional: Executable code
    ├── validate.py             # Validation script
    ├── generate.sh             # Generation script
    └── helpers/                # Supporting utilities
        └── utils.py
```

## File Naming Conventions

| Component | Convention | Example |
|-----------|------------|---------|
| Directory | kebab-case | `pdf-processing/` |
| SKILL.md | Exact case | `SKILL.md` (not `skill.md`) |
| References | lowercase | `api-reference.md` |
| Templates | lowercase | `basic-template.md` |
| Scripts | lowercase | `validate.py` |

## SKILL.md Structure

```markdown
---
name: skill-name
description: What this skill does and when to use it
[optional fields]
---

# Skill Title

## Overview
Brief introduction to what this skill accomplishes.

## Quick Start
Minimal steps to use the skill immediately.

## Core Instructions
Main workflow and guidance.

## Reference Links
- [Detailed API](references/api.md)
- [Examples](references/examples.md)

## Anti-Patterns
What NOT to do.
```

## Progressive Disclosure Strategy

### Tier 1: Always Loaded (~100 tokens)
- `name` field
- `description` field

**Purpose**: Enable Claude to decide when to use the skill.

### Tier 2: On Activation (<5000 tokens)
- Full SKILL.md body
- Core instructions
- Quick reference tables

**Purpose**: Provide actionable guidance without overwhelming context.

### Tier 3: On-Demand (Unlimited)
- `references/*.md` files
- `templates/*` files
- Script outputs (not source)

**Purpose**: Deep documentation available when specifically needed.

## Reference File Guidelines

### When to Create Reference Files

Create separate reference files when:
- Content exceeds 100 lines
- Content is only needed for specific sub-tasks
- Content is highly detailed API documentation
- Content is example-heavy

### Reference File Structure

```markdown
# [Topic] Reference

## Overview
Brief context for this reference.

## [Main Content Sections]
Detailed information organized logically.

## Related
- Links to other relevant references
- External documentation links
```

### Linking References from SKILL.md

Use relative paths:
```markdown
For detailed API information, see [references/api.md](references/api.md).
For usage examples, see [references/examples.md](references/examples.md).
```

## Template File Guidelines

### Purpose of Templates

Templates provide:
- Consistent output formats
- Reusable patterns
- Starter content for common tasks

### Template Structure

```markdown
# [Template Name]

## Usage
When and how to use this template.

## Template

[Actual template content with placeholders]

## Customization
How to adapt the template.
```

### Placeholder Conventions

| Placeholder | Purpose |
|-------------|---------|
| `[SKILL_NAME]` | Name of the skill |
| `[DESCRIPTION]` | Skill description |
| `[INSTRUCTIONS]` | Core instructions |
| `${VARIABLE}` | Dynamic substitution |

## Script File Guidelines

### When to Use Scripts

Scripts are ideal for:
- Validation workflows
- Code generation
- Complex transformations
- External tool invocation

### Script Best Practices

1. **Self-contained**: Include all dependencies
2. **Helpful errors**: Clear error messages
3. **Documentation**: `--help` flag support
4. **Permissions**: Ensure executable (`chmod +x`)

### Script Structure

```python
#!/usr/bin/env python3
"""
Script description.

Usage:
    python script.py [options] <input>
"""

import argparse
import sys

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', help='Input file or value')
    parser.add_argument('--option', help='Optional parameter')
    args = parser.parse_args()

    # Implementation

if __name__ == '__main__':
    main()
```

## Path Conventions

### Relative vs Absolute Paths

| Use | Path Type |
|-----|-----------|
| Within SKILL.md | Relative from skill root |
| Scripts referencing files | Relative or use `$CLAUDE_PROJECT_DIR` |
| External resources | Absolute URLs |

### Path Examples

```markdown
# Good - Relative paths
See [references/api.md](references/api.md)
Run `python scripts/validate.py`

# Good - Environment variables
$CLAUDE_PROJECT_DIR/.claude/skills/

# Bad - Hardcoded absolute
/home/user/.claude/skills/my-skill/
```

## Monorepo Support

Claude Code automatically discovers skills from nested directories:

```
monorepo/
├── .claude/
│   └── skills/           # Root-level skills
│       └── shared-skill/
├── packages/
│   ├── frontend/
│   │   └── .claude/
│   │       └── skills/   # Package-specific skills
│   │           └── ui-components/
│   └── backend/
│       └── .claude/
│           └── skills/
│               └── api-patterns/
```

All skills are discovered and available project-wide.
