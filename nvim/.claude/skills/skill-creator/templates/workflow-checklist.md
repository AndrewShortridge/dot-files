# Skill Creation Workflow Checklist

Use this checklist when creating a new skill from scratch.

---

## Phase 1: Research & Analysis

### Information Gathering

- [ ] **Identify the problem**
  - What task is being repeated?
  - What knowledge gaps does Claude have?
  - What conventions need enforcement?

- [ ] **Analyze existing solutions**
  - [ ] Check `~/.claude/skills/` for similar skills
  - [ ] Check `.claude/skills/` for project skills
  - [ ] Review https://github.com/anthropics/skills
  - [ ] Search web for best practices

- [ ] **Define scope**
  - What will this skill do?
  - What will it NOT do?
  - What tools are required?

### Research Subagent Tasks

```markdown
Spawn in parallel:

1. Explore agent: "Search codebase for [domain] patterns"
2. General-purpose agent: "Fetch [documentation URL]"
3. Explore agent: "Find existing skills in ~/.claude/skills/"
4. General-purpose agent: "Search web for [topic] best practices"
```

---

## Phase 2: Design & Planning

### Skill Design Document

Create a design document answering:

- [ ] **Name**: What is the skill called? (kebab-case)
- [ ] **Description**: What does it do and when to use it?
- [ ] **Triggers**: What user requests should activate it?
- [ ] **Tools**: Which tools needed? Any restrictions?
- [ ] **Structure**: What files will be created?
- [ ] **Disclosure**: What loads immediately vs. on-demand?

### Design Template

```markdown
# Skill Design: [name]

## Problem Statement
[What gap does this skill fill?]

## Trigger Conditions
[List user requests that should activate this skill]

## Tool Requirements
- Required: [tools]
- Restricted: [tools to exclude]

## File Structure
```
skill-name/
├── SKILL.md
├── references/
│   └── [files]
└── templates/
    └── [files]
```

## Progressive Disclosure
- Tier 1 (always): name, description
- Tier 2 (activation): [key sections]
- Tier 3 (on-demand): [reference files]
```

---

## Phase 3: Implementation

### File Creation Order

- [ ] **1. Create directory**
  ```bash
  mkdir -p .claude/skills/[skill-name]/references
  mkdir -p .claude/skills/[skill-name]/templates
  ```

- [ ] **2. Write SKILL.md**
  - [ ] Valid YAML frontmatter
  - [ ] name field (lowercase, hyphens)
  - [ ] description field (what + when + triggers)
  - [ ] Core instructions (<500 lines)
  - [ ] Reference links

- [ ] **3. Write reference files**
  - [ ] Detailed documentation
  - [ ] API references
  - [ ] Examples
  - [ ] Troubleshooting

- [ ] **4. Write templates**
  - [ ] Starter templates
  - [ ] Output format examples
  - [ ] Checklists

- [ ] **5. Add scripts (if needed)**
  - [ ] Validation scripts
  - [ ] Generation scripts
  - [ ] Set execute permissions

### Parallel Implementation Tasks

```markdown
Spawn in parallel:

1. General-purpose agent: "Write SKILL.md following template"
2. General-purpose agent: "Write reference documentation"
3. General-purpose agent: "Write templates"
```

---

## Phase 4: Validation

### Syntax Validation

- [ ] YAML frontmatter valid
- [ ] No blank lines before `---`
- [ ] name is lowercase with hyphens only
- [ ] name is max 64 characters
- [ ] description is max 1024 characters
- [ ] SKILL.md is under 500 lines

### Structure Validation

- [ ] Directory name matches name field
- [ ] SKILL.md exists at root
- [ ] Reference links work
- [ ] Scripts are executable

### Functional Validation

- [ ] Start new Claude session
- [ ] Trigger skill with test prompt
- [ ] Verify skill activates
- [ ] Follow complete workflow
- [ ] Check reference files load
- [ ] Test edge cases

### Test Prompts

Use these prompts (customize for your skill):

```
"[Keyword from description] help"
"I need to [action from description]"
"How do I [workflow from skill]?"
```

---

## Phase 5: Iteration

### Observation Checklist

After using the skill in real scenarios:

- [ ] Does it activate at appropriate times?
- [ ] Does it miss relevant requests?
- [ ] Does it activate for wrong requests?
- [ ] Are instructions followed correctly?
- [ ] Is any content ignored?
- [ ] Are there missing instructions?

### Refinement Actions

Based on observations:

- [ ] Refine trigger terms in description
- [ ] Clarify ambiguous instructions
- [ ] Remove unused content
- [ ] Add missing guidance
- [ ] Improve examples
- [ ] Update anti-patterns

---

## Quick Reference

### File Locations

| Scope | Path |
|-------|------|
| Personal | `~/.claude/skills/` |
| Project | `.claude/skills/` |

### Naming Rules

| Component | Rule |
|-----------|------|
| Directory | kebab-case |
| name field | lowercase, hyphens, max 64 |
| SKILL.md | Exact case |

### Size Limits

| Field | Limit |
|-------|-------|
| name | 64 characters |
| description | 1024 characters |
| SKILL.md | 500 lines recommended |
| Tier 2 content | <5000 tokens |

### Description Formula

```
[What it does] + [When to use it] + [Trigger keywords]
```
