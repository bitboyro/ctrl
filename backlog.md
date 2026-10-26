# Follow-up scope after the operations overhaul

- Real disposable Docker/Compose/OpenSSH/rsync integration is covered by the opt-in
  suite. Production migration still needs review of actual deployment configuration.
- Project builds need reviewed implementations, not a core build framework.
  Public examples use fictional application names and placeholder infrastructure.
- v1 targets run sequentially. Add bounded concurrency only with a demonstrated
  need and per-target audit/cancellation tests.
- No downloadable third-party operation registry. Ship a small first-party library
  and let projects commit reviewed local scripts/contracts.
- Remote cancellation cannot guarantee remote process-tree termination after SSH
  disconnect. Durable jobs need a separate job manager.
- Journal is local, not tamper-evident. Centralized export/retention belongs in an
  explicitly configured integration if required.
