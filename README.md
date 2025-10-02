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

## Getting Started

### Prerequisites

- Kubernetes cluster (local or cloud)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured
- [Docker](https://www.docker.com/) (for local environments)

### Environment Setup

For setting up your CloudNativePG environment, follow the official:

📚 **[CloudNativePG Playground Setup Guide](https://github.com/cloudnative-pg/cnpg-playground/blob/main/README.md)**

After completing the playground setup, verify your environment is ready for chaos testing:

```bash
# Clone this chaos testing repository
git clone https://github.com/cloudnative-pg/chaos-testing.git
cd chaos-testing

# Verify environment readiness for chaos experiments
./scripts/check-environment.sh
```

### LitmusChaos Installation

Install LitmusChaos using the official documentation:

- **[LitmusChaos Installation Guide](https://docs.litmuschaos.io/docs/getting-started/installation)**
- **[Chaos Center Setup](https://docs.litmuschaos.io/docs/getting-started/installation#install-chaos-center)** (optional, for UI-based management)
- **[LitmusCTL CLI](https://docs.litmuschaos.io/docs/litmusctl-installation)** (for command-line management)

### Running Chaos Experiments

Once your environment is set up, you can start running chaos experiments:

📖 **[Follow the Experiment Guide](./EXPERIMENT-GUIDE.md)** for detailed instructions on:

- Available chaos experiments
- Step-by-step execution
- Results analysis and interpretation
- Troubleshooting common issues

## Quick Experiment Overview

This repository includes several pre-configured chaos experiments:

| Experiment             | Description                                    | Risk Level |
| ---------------------- | ---------------------------------------------- | ---------- |
| **Replica Pod Delete** | Randomly deletes replica pods to test recovery | Low        |
| **Primary Pod Delete** | Deletes primary pod to test failover           | High       |
| **Random Pod Delete**  | Targets any pod randomly                       | Medium     |

## Project Structure

```
chaos-testing/
├── README.md                          # This file
├── EXPERIMENT-GUIDE.md                # Detailed experiment instructions
├── experiments/                       # Chaos experiment definitions
│   ├── cnpg-replica-pod-delete.yaml   # Replica pod chaos
│   ├── cnpg-primary-pod-delete.yaml   # Primary pod chaos
│   └── cnpg-random-pod-delete.yaml    # Random pod chaos
├── scripts/                           # Utility scripts
│   ├── check-environment.sh           # Environment verification
│   └── get-chaos-results.sh           # Results analysis
├── pg-eu-cluster.yaml                 # PostgreSQL cluster configuration
└── litmus-rbac.yaml                   # Chaos experiment permissions
```

## License & Code of Conduct

This project is licensed under Apache-2.0. See the [LICENSE](./LICENSE)
file for details.

Please adhere to the [Code of Conduct](./CODE_OF_CONDUCT.md) in all
contributions.
