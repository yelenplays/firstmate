### Missing credential stops without a proposal
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> []
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: no Jev key configured (TYPESAFE_API_KEY or OPENROUTER_API_KEY); nothing sent, no proposal written

Observed state: isolated config, data and state unchanged.

### Directory output
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/home/data/model-proposals']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: output target is a directory: <lab>/home/data/model-proposals; choose a proposal file

Observed state: isolated config, data and state unchanged.

### Directory symlink output
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/directory-link']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: output target is a directory: <lab>/directory-link; choose a proposal file

Observed state: isolated config, data and state unchanged.

### Nested configuration output
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/home/config/new/nested/proposal.md']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: refusing to write under protected path <lab>/home/config

Observed state: isolated config, data and state unchanged.

### Runtime-state output
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/home/state/new/proposal.md']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: refusing to write under protected path <lab>/home/state

Observed state: isolated config, data and state unchanged.

### Input overwrite
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/evidence.json']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: refusing to overwrite the input file <lab>/evidence.json

Observed state: isolated config, data and state unchanged.

### Private model identifier is refused without echoing it
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/home/data/blocked.md']
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: request text matches <lab>/home/config/dispatch-never-send line 1

Observed state: isolated config, data and state unchanged.

### Malformed current model is refused before generating a proposal
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> []
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: dispatch profile file <lab>/home/config/crew-dispatch.json is malformed

Observed state: isolated config, data and state unchanged.

### Fable mislabeled as subscription is refused
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> []
Exit: 2
Stdout: 
Stderr: fm-jev-model-proposal: evidence file <lab>/evidence.json: a Fable model must be marked billing usage-credits

Observed state: isolated config, data and state unchanged.

### Oversized state gives a readable no-answer proposal through resolved data output
Command: bash bin/fm-jev-model-proposal.sh --evidence <isolated-input> ['--out', '<lab>/home/config/new/../../data/oversized-proposal.md']
Exit: 1
Stdout: <lab>/home/data/oversized-proposal.md
Stderr: fm-jev-model-proposal: 2 of 2 roles got no usable answer

Observed output: two unique request IDs match the persisted log; each role has no answer and no switch. Fable usage-credit notice present. Config tree and bytes unchanged; config/new absent. Both call records have empty route/model/HTTP: no provider call attempted.

Credential availability: neither TYPESAFE_API_KEY nor OPENROUTER_API_KEY is supplied by this process; no .env exists in the run source. No production credentials were accessed or changed. Successful Jev-backed proposal remains untested.
