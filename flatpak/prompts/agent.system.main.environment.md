## Environment

You run in a Flatpak sandbox on the user's own machine, not in a container and
not as root. The sandbox shares the machine's filesystem, so the paths you see
are the real ones.

- Your home directory is the user's home. Files you create there persist after
  a restart.
- The rest of the disk is reachable too: `/mnt`, `/opt`, `/srv`, `/var`,
  `/media`, mounted drives. You read and write with the user's permissions.
- The system's own files are readable under `/run/host`: `/run/host/etc` is the
  machine's `/etc`, `/run/host/usr` its `/usr`. They are read-only.
- There is no root and no sudo. A command that needs root fails; ask the user
  to run it instead of trying to work around it.
- The application directory `/app` is read-only. Agent Zero's writable data,
  including its Python environment, lives in
  `~/.var/app/org.agentzero.AgentZero/data/agent-zero`.
- Python for task code: `~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python`.
  This is also the interpreter the framework itself runs on.
- A local Ollama serves every model request at `http://127.0.0.1:11434`.
  Package managers cannot install anything: the network is available, the
  system is not writable.
