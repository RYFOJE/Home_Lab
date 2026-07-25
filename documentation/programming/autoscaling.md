# Autoscaling

KEDA is installed cluster-wide (`kubernetes/apps/autoscaling/keda`). Scaling an
app means adding resources to that app's own directory — nothing in the `keda`
app changes, and no cluster-level step is needed to enable a trigger type. All
scalers, Azure Service Bus included, are built into the operator.

## Scale on an Azure Service Bus queue

Store the connection string in Key Vault as `<namespace>--servicebus-connection`
(`../secrets.md`). Use a `Listen`-scoped SAS string for the one queue, not the
namespace-wide `RootManageSharedAccessKey`. A connection string rather than
workload identity: federated identity needs an OIDC issuer Azure AD can reach,
which this cluster does not expose.

Then add three resources to your app's `templates/`, all in your own namespace:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: servicebus-connection
spec:
  secretStoreRef:
    name: azure-kv
    kind: ClusterSecretStore
  target:
    name: servicebus-connection
  data:
    - secretKey: connectionString
      remoteRef:
        key: <namespace>--servicebus-connection
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: servicebus-connection
spec:
  secretTargetRef:
    - parameter: connection
      name: servicebus-connection
      key: connectionString
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: <app>
spec:
  scaleTargetRef:
    name: <app>          # the Deployment name
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: azure-servicebus
      metadata:
        queueName: <queue>
        messageCount: "5"
      authenticationRef:
        name: servicebus-connection
```

For a topic, replace `queueName` with `topicName` plus `subscriptionName`.

Use `TriggerAuthentication`, never `ClusterTriggerAuthentication`: the
cluster-scoped kind reads its Secret from the `keda` namespace, and a Kyverno
policy denies any `ExternalSecret` reaching for another namespace's Key Vault
prefix (`gitops_apps.md`).

Do not set `replicas` on a Deployment that a `ScaledObject` targets — KEDA owns
the field, and a value in the manifest fights ArgoCD's self-heal.

## Knobs

| Field | Default | Effect |
|---|---|---|
| `minReplicaCount` | `0` | `0` scales to zero when idle; KEDA polls the queue directly to wake it |
| `maxReplicaCount` | `100` | Ceiling |
| `pollingInterval` | `30` | Seconds between trigger checks |
| `cooldownPeriod` | `300` | Seconds of idle before scaling to zero; applies only on the last replica |
| `messageCount` | `5` | Queue depth per replica — the scaling ratio, not a threshold |
| `activationMessageCount` | `0` | Depth that wakes a scaled-to-zero workload |

`messageCount` is a divisor: 50 queued messages at `messageCount: 5` requests
10 replicas.

## Other triggers

Every scaler in <https://keda.sh/docs/latest/scalers/> works here, and the
metadata fields on that page apply verbatim. `prometheus` scales on a PromQL
query against `http://kube-prometheus-stack-prometheus.monitoring:9090` and
needs no authentication; `cron` needs no secret either. Anything else follows
the credential pattern above.

## Checking it works

```
kubectl get scaledobject -n <namespace>
```

`READY=True` and `ACTIVE=True` means the trigger is reachable and returning a
non-zero metric. `READY=False` is usually a bad credential or an unreachable
endpoint:

```
kubectl describe scaledobject <app> -n <namespace>
kubectl logs -n keda deploy/keda-operator
```

KEDA creates an HPA named `keda-hpa-<scaledobject>`; `kubectl get hpa -n
<namespace>` shows the current metric against the target. A scaled-to-zero
workload has no HPA until the trigger activates.
