# Project Instructions

## Overview
This project provides mcp servers for agentic coding with strong guard rails. 

## Guidelines

### Code style
- Avoid unnecessary indirection, some repetition of trivial code is acceptable
- Avoid massive amounts of boiler plate, if we keep on repeating ourselves break out the code into a clearly named helper function

### File length
- Avoid files longer than 500 lines
- If you add files to a file longer than 500 lines, break down the file into smaller files and commit this refactor before adding the new code

### Shared code
- Business logic or slightly more complex helper functions that are used by more than one package should be broken out into ./packages/shared_libs.

### Skills and Agents
- If you update skills or agents, make sure you clearly inform the user that a new plugin needs to be built. Use a interactive dialog to make the user confirm they have understood.

## Resources
- The Complete Guide to Building Skills for Claude: https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf?hsLang=en
- Build an MCP server: https://modelcontextprotocol.io/docs/develop/build-server