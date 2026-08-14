# Design References

This project's approach draws on similar agent-container projects and official documentation:

- [OpenHands agent-server image](https://github.com/OpenHands/software-agent-sdk) — parameterized builds,
  pinned tool versions, `COPY --from` for uv, cache mounts, OCI labels, fail-fast builds;
- [mattolson/agent-sandbox](https://github.com/mattolson/agent-sandbox) — pinned tool versions, a separate
  persistent state volume, and a sandbox that grants only minimal filesystem/network access;
- [Claude Code dev container documentation](https://code.claude.com/docs/en/devcontainer) — auth/state volume
  mounting and `CLAUDE_CONFIG_DIR` on the same volume, an in-container auto-update kill switch
  (`DISABLE_AUTOUPDATER` corresponds to our `DSH_AUTO_UPDATE=0`), and the warning against mounting host
  keys into the container;
- [Running Claude Code in Docker (Dennis van der Stelt)](https://github.com/dvdstelt/weblog/blob/main/src/content/posts/2026-02-19-claude-code-in-docker.md) — the host-side launch-script wrapper around `docker run` experience.
