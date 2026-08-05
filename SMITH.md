# Smith Project Instructions

## Skill Storage Policy

When creating or managing skills for Smith, adhere to the following storage locations:

1. **Project-local skills (Recommended for project-specific tasks)**:
   - Path: `.smith/skills/<skill-name>/SKILL.md`
   - Example: `.smith/skills/test/SKILL.md`

2. **Global skills (Available across all projects)**:
   - Path: `~/.smith/skills/<skill-name>/SKILL.md`
   - Example: `~/.smith/skills/git-commit/SKILL.md`

> **Instruction for Smith**: If the user asks to create a new skill without specifying whether it should be project-local or global, ask the user first where they want to store the skill before creating the file.
