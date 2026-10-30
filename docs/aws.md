<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/docs-aws-dark.png">
  <img alt="FEMME docs: AWS" src="../assets/docs-aws-light.png" width="100%">
</picture>

## The server's own AWS access

By default the server gets no AWS access. With `AWS_ROLE=spawn` in `.env`, `provision.sh` gives the instance a role (`femme`) that may launch, stop and terminate the instance types in `SPAWN_TYPES` in `REGION`, and nothing else. The credentials come from the instance metadata service and rotate themselves, so there is no key on disk; but anything running on the server, agents included, can use them. Grant more by hand only if you accept that.

Set a hard spend brake either way: in Service Quotas, lower "Running On-Demand Standard instances" (vCPUs) for the region. Add a Budgets email alert too, but alerts lag hours and stop nothing.
