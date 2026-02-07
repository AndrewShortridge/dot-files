# Skill Validation Checklist

Use this checklist before deploying a new skill.

## Pre-Deployment Checklist

### 1. File Structure

- [ ] Directory name matches `name` field (kebab-case)
- [ ] `SKILL.md` file exists at directory root (exact case)
- [ ] `SKILL.md` is under 500 lines
- [ ] Reference files are in `references/` subdirectory
- [ ] Template files are in `templates/` subdirectory
- [ ] Scripts have execute permissions (`chmod +x`)
- [ ] All paths use Unix-style forward slashes

### 2. YAML Frontmatter

- [ ] Frontmatter starts with `---` on line 1
- [ ] No blank lines before opening `---`
- [ ] Closing `---` present
- [ ] Uses spaces for indentation (not tabs)
- [ ] `name` field is present
- [ ] `name` is lowercase with hyphens only
- [ ] `name` is max 64 characters
- [ ] `description` field is present
- [ ] `description` is max 1024 characters
- [ ] `description` contains no XML tags
- [ ] Optional fields have valid values

### 3. Description Quality

- [ ] Describes WHAT the skill does
- [ ] Describes WHEN to use it
- [ ] Includes relevant trigger keywords
- [ ] Specific enough to avoid false matches
- [ ] Distinct from other skills' descriptions

### 4. Content Quality

- [ ] Instructions are actionable
- [ ] No redundant/obvious information
- [ ] Anti-patterns documented
- [ ] Examples provided where helpful
- [ ] Reference links work correctly
- [ ] No hardcoded absolute paths

### 5. Tool Restrictions (if applicable)

- [ ] `allowed-tools` lists all needed tools
- [ ] Tool names are spelled correctly
- [ ] Bash patterns are valid
- [ ] No unnecessary tool restrictions

### 6. Scripts (if applicable)

- [ ] Scripts have `--help` documentation
- [ ] Scripts have clear error messages
- [ ] Dependencies documented in compatibility field
- [ ] Scripts tested independently
- [ ] No sensitive data in scripts

### 7. Hooks (if applicable)

- [ ] Hook commands exist and are executable
- [ ] Matchers use valid regex patterns
- [ ] `once: true` used where appropriate
- [ ] Hook outputs don't break workflow

---

## Testing Procedure

### Step 1: Syntax Validation

```bash
# Check YAML syntax
head -20 .claude/skills/[skill-name]/SKILL.md

# Verify no leading whitespace/blank lines
cat -A .claude/skills/[skill-name]/SKILL.md | head -5

# Check line count
wc -l .claude/skills/[skill-name]/SKILL.md
```

### Step 2: Discovery Test

1. Start a new Claude Code session
2. Run `claude --debug` to see skill discovery
3. Verify skill appears in discovered skills list

### Step 3: Activation Test

1. Ask a question that should trigger the skill
2. Claude should request permission to use the skill
3. Confirm the skill activates

**Test Prompts** (customize for your skill):
- "[Keyword from description] help"
- "I need to [action mentioned in description]"
- "How do I [workflow described in skill]?"

### Step 4: Functionality Test

1. Follow a complete workflow in the skill
2. Verify instructions are followed correctly
3. Check that referenced files load properly
4. Test any scripts execute correctly

### Step 5: Edge Case Test

- Test with minimal input
- Test with complex/large input
- Test error handling
- Test tool restrictions work

---

## Common Issues and Fixes

### Skill Not Discovered

| Symptom | Cause | Fix |
|---------|-------|-----|
| Not in skill list | Wrong location | Move to `~/.claude/skills/` or `.claude/skills/` |
| Not in skill list | File named wrong | Rename to exactly `SKILL.md` |
| Not in skill list | Invalid YAML | Check frontmatter syntax |

### Skill Not Triggering

| Symptom | Cause | Fix |
|---------|-------|-----|
| Never activates | Vague description | Add specific trigger terms |
| Wrong skill activates | Overlapping descriptions | Make descriptions more distinct |
| Activates incorrectly | Too broad description | Narrow the scope |

### Skill Errors During Use

| Symptom | Cause | Fix |
|---------|-------|-----|
| Can't use tools | `allowed-tools` too restrictive | Add missing tools |
| Script fails | Missing dependency | Document in `compatibility` |
| Path not found | Hardcoded path | Use relative paths |
| Reference not loading | Wrong link format | Use `[text](path)` format |

### Hook Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Hook not running | Script not executable | `chmod +x script.sh` |
| Hook blocks workflow | Script returns error | Fix script or add error handling |
| Hook runs too often | Missing `once: true` | Add `once: true` for one-time hooks |

---

## Iteration Checklist

After initial deployment, observe and iterate:

### Observation Points

- [ ] Does Claude activate the skill at appropriate times?
- [ ] Does Claude follow instructions correctly?
- [ ] Are there unexpected exploration paths?
- [ ] Is any content consistently ignored?
- [ ] Are users triggering it with unexpected phrases?

### Iteration Actions

Based on observations:

- [ ] Refine trigger terms in description
- [ ] Clarify ambiguous instructions
- [ ] Remove unused content
- [ ] Add missing guidance
- [ ] Improve anti-pattern documentation

### Version Control

- [ ] Commit working versions before changes
- [ ] Document significant changes
- [ ] Test after each change
- [ ] Roll back if issues arise
