# R9 — data, regional loss and return to the original region

Status: implemented; the `continuity` job publishes measurements for each commit.
Nothing in v2 has run on Azure. A Docker result does not certify SLA, latency,
managed replication or PostgreSQL Flexible Server promotion.

## Reproducible experiment without a cloud account

`make continuity` requires the two images already built by CI. This is a heavy
experiment intended for Actions. It does not build a different image from the
one approved by the scanners.

1. Create A and B with independent backend/frontend networks and disks. Neither
   database publishes a host port. Only the app publishes loopback HTTP on a random port.
2. Recover a package of ephemeral configuration and secrets by checksum. Check
   image IDs; the package and private keys never enter artifacts.
3. Use PostgreSQL with `verify-full` TLS, an ephemeral CA and SAN `db`. The API
   mounts only the public CA. The database and frontend share no direct network.
4. Write a marker through nginx and the API, stop the database, and prove reads
   fail. Restart the database and require recovery through the same API container.
5. Run `pg_dump -Fc`, check its catalog and SHA256, write a later transaction,
   and require promotion to be rejected while the primary remains alive.
6. Corrupt a backup copy and require rejection before any restore.
7. Stop every A writer, verify fencing, and destroy its disk. Restore B from
   the intact backup and start the same application version.
8. Require the earlier marker and absence of the transaction after the backup.
   Measure RPO from the start of the consistent backup to failure; RTO runs from
   failure until B serves the app and confirms the data. Local limits: 120 s/180 s.
9. Write in B, produce another backup, fence B and rebuild A on a new disk.
   Failback must preserve both original data and writes from B within 180 s.
   B must remain unable to write.

`continuity/continuity.json` records checksums, image IDs, RPO, RTO, failback time
and the intentional loss of one transaction. Errors fail the job. Cleanup checks
the unique run label before removing each resource. It does not use another
task's volume, network, Kubernetes context or Compose project.

## What each layer recovers

| Layer | Mechanism | Evidence |
|---|---|---|
| API reconnection | Pool discards broken connections and opens new ones | Database interruption, same API container |
| Application logical backup | `pg_dump`, catalog and SHA256 | Marker preserved; corruption rejected |
| Physical archive/WAL and PITR | `tx02v2` exercise | Verified base backup, restore point, recovered deleted transaction |
| Kubernetes PVC | Velero in `tx02v2` | Coordinated infrastructure exercise requires a matching checksum after deleting the original PVC |
| Environment loss and failback | Independent A/B networks and disks | `continuity` job, fencing and preservation of new data |
| Images and supply chain | The same `images` job artifact, signed release on deployment | Same IDs in A/B, R7 gates |
| Managed database and runtime | `dr` profile and `tx02v2` runbook | Terraform mocks/validation; not run in the cloud |

In cloud, confirm the contract's plan and region before changing anything.
Block GitOps/deployments and old writers before promoting the replica; a DNS
change alone does not prevent split brain. Follow the pair's runbook, monitor
lag, save RPO/RTO evidence, and fail back only after consistently reseeding the
original region. If the original region cannot be isolated, stop promotion and
escalate to the operator.

Do not copy a local `.env` to cloud. Regional secrets remain in Key Vault and
regional workload identities. Promotion publishes already signed digests in
the recovered region's registry; it must not rebuild the code.

## Regional deployment target

`deploy-azure` offers `target=primary|secondary`. Secondary reads
`AZURE_DR_APPCONFIG_ENDPOINT` (TX output), uses the DR region's AKS/ACR/Key Vault,
and publishes `gitops/azure-dr`. ExternalSecret references are rendered for DR
secrets while retaining the resource group and identities specified by the contract.

Before moving the CNAME, fence primary writers, check lag/latest backup, and
promote the replica with human authorization. In secondary AKS, restore the TLS
Secret labeled `lab.continuity/tls=true` from backup following the TX runbook.
The full-profile smoke uses `curl --resolve` against the selected Gateway address,
preserving SNI and certificate verification; it requires the published revision
and application reads/writes. It does not approve standby using old DNS.

CI checks both targets and secret references offline. Real A/B continuity runs
in Docker in Actions; managed promotion and ACME issuance/renewal have not run
on Azure in this version.
