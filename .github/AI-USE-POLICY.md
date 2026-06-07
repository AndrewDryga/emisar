# AI Use Policy

This repository is source-available, but it is **not** available for AI training, model replication, clean-room cloning, or competitive reconstruction.

This policy explains how the AI-related restrictions in `LICENSE.md` apply in practice.

## Allowed

You may use ordinary developer tools to understand and work with the code, provided your use complies with the license.

Allowed examples:

- reading the code yourself;
- using local editor autocomplete that does not train on this repository;
- using a code formatter, linter, compiler, static analyzer, type checker, or dependency scanner;
- using security scanning tools to find vulnerabilities;
- asking an AI assistant to explain a small snippet that you wrote or that is already public, as long as you do not upload substantial repository content, use the repository as training data, or generate a competing implementation;
- submitting a contribution if you have the legal right to submit it and it does not violate third-party terms.

## Not Allowed

You may not use this repository, any fork, any derivative work, or any repository content to:

- train, fine-tune, continue-train, pre-train, post-train, align, distill, benchmark, evaluate, or improve an AI model;
- create embeddings, vector indexes, retrieval corpora, code-search corpora, synthetic datasets, prompt libraries, or benchmark suites for AI systems;
- generate an implementation plan, architecture summary, API-compatible clone, feature clone, or substitute product;
- perform clean-room replication using humans, contractors, AI systems, or a combination of them;
- use this repository as a target, oracle, reference implementation, verifier, evaluator, or reward source for an AI system;
- use model outputs, synthetic data, transformed representations, intermediate specifications, or other indirect artifacts to bypass the license;
- scrape, mirror, ingest, cache, or index repository content for AI-related use;
- help a third party do any of the above.

## Examples

### Example: "Can I use Copilot while editing my own contribution?"

Usually yes, if your use of the tool does not upload substantial repository content for training, does not violate the tool's terms, and you have the legal right to submit the resulting contribution.

You remain responsible for the contribution.

### Example: "Can I put the whole repo into an AI coding agent and ask it to build a competitor?"

No.

### Example: "Can I create embeddings of the repo for semantic code search?"

No, unless you have written permission from the Licensor.

### Example: "Can I use an AI tool to summarize one file for internal evaluation?"

Only if the use is internal, non-commercial, not used to train or improve an AI system, not retained in a retrieval corpus, and not used to reproduce or compete with the project. When in doubt, ask first.

### Example: "Can I use the code to create tests for a clean-room reimplementation?"

No.

### Example: "Can I benchmark my product against this project?"

Not for publication or competitive use without prior written permission.

## Requesting Permission

For permission to use this repository for an AI-related purpose, email `licensing@emisar.dev` with:

- who you are;
- what materials you want to use;
- what system or model will use them;
- whether the use involves training, fine-tuning, embeddings, retrieval, benchmarking, evaluation, or generated code;
- whether the results will be public or commercial;
- how the materials will be retained, deleted, or audited.

Permission is not granted unless Licensor confirms it in a separate written agreement.
