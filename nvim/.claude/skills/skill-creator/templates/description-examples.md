# Description Writing Examples

The description field is critical - Claude uses semantic matching to decide when to apply skills.

## Formula

```
[What it does] + [When to use it] + [Trigger keywords]
```

---

## Examples by Category

### Document Processing

```yaml
# PDF Processing
description: >
  Extract text and tables from PDF files, fill forms, merge and split documents.
  Use when working with PDF files or when the user mentions PDFs, forms,
  document extraction, or PDF manipulation.

# Word Documents
description: >
  Create, edit, and analyze Word documents with tracked changes and comments.
  Use when working with .docx files, Word documents, or document collaboration
  with revision tracking.

# Excel Spreadsheets
description: >
  Create and manipulate Excel spreadsheets with formulas, charts, and data analysis.
  Use when working with .xlsx files, spreadsheets, pivot tables, or financial models.

# PowerPoint
description: >
  Create professional presentations with consistent styling and layouts.
  Use when working with .pptx files, slide decks, or presentation design.
```

### Development Tools

```yaml
# Testing
description: >
  Run and debug tests using Playwright for web application testing.
  Use when testing web apps, browser automation, E2E testing, or verifying
  frontend functionality.

# API Development
description: >
  Design and implement RESTful APIs with proper error handling and documentation.
  Use when creating API endpoints, handling HTTP requests, or building backend services.

# Database Operations
description: >
  Write and optimize SQL queries, design schemas, and manage database migrations.
  Use when working with databases, SQL, PostgreSQL, MySQL, or data modeling.

# Docker/Containers
description: >
  Create Dockerfiles, docker-compose configurations, and manage container deployments.
  Use when containerizing applications, working with Docker, or setting up
  development environments.
```

### Code Quality

```yaml
# Code Review
description: >
  Review code changes for quality, security, and best practices.
  Use when reviewing PRs, analyzing code quality, or checking for security issues.

# Refactoring
description: >
  Identify and execute code refactoring opportunities to improve maintainability.
  Use when cleaning up code, reducing technical debt, or improving code structure.

# Documentation
description: >
  Generate and maintain code documentation, API docs, and README files.
  Use when documenting code, writing API references, or creating developer guides.
```

### DevOps/Infrastructure

```yaml
# CI/CD
description: >
  Create and maintain CI/CD pipelines for automated testing and deployment.
  Use when setting up GitHub Actions, GitLab CI, or deployment automation.

# Kubernetes
description: >
  Write Kubernetes manifests, Helm charts, and manage cluster deployments.
  Use when working with K8s, container orchestration, or cloud-native deployments.

# Terraform
description: >
  Create and manage infrastructure as code using Terraform.
  Use when provisioning cloud resources, managing IaC, or setting up AWS/GCP/Azure.
```

### Creative/Design

```yaml
# UI Design
description: >
  Design user interfaces with modern aesthetics and accessibility standards.
  Use when creating UI components, designing layouts, or implementing design systems.

# Generative Art
description: >
  Create algorithmic and generative art using p5.js or similar libraries.
  Use when making creative coding projects, generative visuals, or interactive art.

# Branding
description: >
  Apply consistent brand guidelines to designs and content.
  Use when implementing brand colors, typography, or visual identity standards.
```

---

## Trigger Term Strategies

### File Extensions

Include relevant extensions:
- `.pdf`, `.xlsx`, `.docx`, `.pptx`
- `.ts`, `.tsx`, `.js`, `.jsx`
- `.py`, `.go`, `.rs`, `.java`

### Action Verbs

Include common actions:
- Create, generate, build, make
- Edit, update, modify, change
- Extract, parse, analyze, process
- Convert, transform, migrate
- Test, validate, verify, check
- Deploy, release, publish

### Domain Terms

Include field-specific terminology:
- Authentication, authorization, OAuth, JWT
- REST API, GraphQL, endpoints
- Database, schema, migration, query
- Components, hooks, state management
- Pipeline, workflow, automation

### Tool Names

Include tool/library names users mention:
- Playwright, Jest, Vitest, pytest
- React, Vue, Angular, Svelte
- pandas, numpy, matplotlib
- Docker, Kubernetes, Terraform

---

## Anti-Patterns

### Too Vague

```yaml
# Bad
description: Helps with files

# Bad
description: Code helper

# Bad
description: Data processing
```

### Too Long (Over 1024 chars)

Keep descriptions concise. Move details to SKILL.md body.

### Missing Trigger Conditions

```yaml
# Bad - No "when to use"
description: Extracts text from PDFs and fills forms.

# Good - Includes trigger conditions
description: >
  Extract text from PDFs and fill forms.
  Use when working with PDF files or document extraction.
```

### Overlapping with Other Skills

Make descriptions distinct:

```yaml
# Skill 1: Sales Data
description: >
  Analyze sales data in Excel files and CRM exports.
  Use for sales reports, revenue analysis, and forecasting.

# Skill 2: System Logs (distinct from Skill 1)
description: >
  Analyze system logs and application metrics.
  Use for debugging, performance analysis, and monitoring.
```

---

## Testing Your Description

Ask yourself:
1. Would Claude match this to relevant user requests?
2. Would Claude avoid matching irrelevant requests?
3. Are the trigger terms specific enough?
4. Is it distinct from other skills?

Test with prompts:
- "[Keyword] help" - Should trigger
- "Tell me about [topic]" - Should trigger
- Unrelated request - Should NOT trigger
