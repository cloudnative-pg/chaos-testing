[![CloudNativePG](./logo/cloudnativepg.png)](https://cloudnative-pg.io/)

# CloudNativePG Chaos Testing

**Chaos Testing** is a project to strengthen the resilience, fault-tolerance,
and robustness of **CloudNativePG** through controlled experiments and failure
injection.

This repository is part of the [LFX Mentorship (2025/3)](https://mentorship.lfx.linuxfoundation.org/project/0858ce07-0c90-47fa-a1a0-95c6762f00ff),
with **Yash Agarwal** as the mentee. Its goal is to define, design, and
implement chaos tests for CloudNativePG to uncover weaknesses under adverse
conditions and ensure PostgreSQL clusters behave as expected under failure.

---

## Motivation & Goals

- Identify weak points in CloudNativePG (e.g., failover, recovery, slowness,
  resource exhaustion).
- Validate and improve handling of network partitions, node crashes, disk
  failures, CPU/memory stress, etc.
- Ensure behavioral correctness under failure: data consistency, recovery,
  availability.
- Provide reproducible chaos experiments that everyone can run in their own
  environment — so that behavior can be verified by individual users, whether
  locally, in staging, or in production-like setups.
- Use a common, established chaos engineering framework: we will be using
  [LitmusChaos](https://litmuschaos.io/), a CNCF-hosted, incubating project, to
  design, schedule, and monitor chaos experiments.
- Support confidence in production deployment scenarios by simulating
  real-world failure modes, capturing metrics, logging, and ensuring
  regressions are caught early.

## License & Code of Conduct

This project is licensed under Apache-2.0. See the [LICENSE](./LICENSE)
file for details.

Please adhere to the [Code of Conduct](./CODE_OF_CONDUCT.md) in all
contributions.
