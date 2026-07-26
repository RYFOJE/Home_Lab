#!/usr/bin/env python3
"""
Renders every chart this cluster admits resources from -- the GitOps apps under
kubernetes/apps (via the bootstrap registry) and the Terraform-pinned upstream
charts (via their renovate-annotated tfvars, with the values files those layers
actually apply) -- and checks the result against what
kubernetes/apps/security/kyverno-policies enforces at admission time:

  - every container/initContainer/ephemeralContainer image resolves to an
    allow-listed registry, and carries an explicit tag or digest that is not
    ':latest' (image-supply-chain)
  - every Namespace a chart renders for itself carries a
    pod-security.kubernetes.io/enforce label whose value is baseline or
    restricted (outside the named privileged exceptions), and every app that
    owns its destination namespace pairs createNamespace with namespaceLabels
    (require-namespace-psa-label)
  - every rendered object stays under the 262144-byte
    last-applied-configuration cap, or the owning app sets
    ServerSideApply=true in the bootstrap registry

Rendering the Terraform charts with their real values files is a check in its
own right, separate from the policy rules: a chart that ships a
values.schema.json refuses an unknown key, and one that does not silently drops
it. Both classes of bug reached this repository while CI rendered chart
defaults, and both surface here now as a failed render or a diffable output.

Only the third of those is unique to this script. The first two are a
hand-written mirror of rules the Kyverno engine can evaluate itself, and a
mirror can drift -- so CI does not rely on it: `--dump <dir>` writes every
rendered manifest out, and the workflow then runs the real policies over that
directory with the Kyverno CLI (see .github/workflows/cluster-policy-check.yml).
The mirror stays because it produces a readable per-image diagnostic and runs
without a second toolchain; the CLI pass is what actually has authority, and it
catches the class of bug the mirror structurally cannot -- an unresolved
variable, a broken autogen rewrite, a rule that errors instead of denying.

This still does not replace the live admission webhook. It exists to catch a
chart bump introducing a new registry, a namespace with a missing or
`privileged` PSA label, or an object crossing the size cap, before merge rather
than at wave -1/-2 on the next sync or on the next pod restart after one.

Not covered, and deliberately so: the Terraform-created namespaces
(kubernetes_namespace resources), which would mean parsing HCL.

Run locally: python scripts/check_cluster_policy.py
"""
import atexit
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: pip install pyyaml")

# PyYAML has no default constructor for the YAML 1.1 "=" (tag:yaml.org,2002:value)
# scalar, so a bare '=' anywhere in a chart's rendered output (e.g. embedded
# dashboard/example content) raises instead of parsing as the string "=".
yaml.SafeLoader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)

REPO_ROOT = Path(__file__).resolve().parent.parent

# Mirrors kubernetes/apps/security/kyverno-policies/files/policies.yaml
# restrict-image-registries -- keep the two in sync.
ALLOWED_REGISTRIES = {
    "docker.io",
    "ghcr.io",
    "quay.io",
    "registry.k8s.io",
    "reg.kyverno.io",
    "ecr-public.aws.com",
}

PSA_LABEL = "pod-security.kubernetes.io/enforce"

# Mirrors require-namespace-psa-label's restrict-psa-enforce-level rule: the
# label must exist everywhere, and outside these two namespaces its value must
# be baseline or restricted. `privileged` opts a namespace out of the cluster's
# workload-hardening layer, so the exception list is deliberately short and
# lives in a diff -- keep it in sync with the policy.
PSA_ALLOWED_LEVELS = {"baseline", "restricted"}
PSA_PRIVILEGED_NAMESPACES = {"longhorn-system", "monitoring-system"}

# require-namespace-psa-label excludes the four namespaces the API server
# creates for itself -- nothing in this repo can label them.
API_SERVER_NAMESPACES = {"default", "kube-system", "kube-public", "kube-node-lease"}

# The one app whose namespace is created by Terraform (60-argo-cd gitops.tf),
# which sets the PSA label there. Its registry entry keeps createNamespace for
# a from-scratch ordering safety net but deliberately carries no
# namespaceLabels: kubernetes_namespace replaces the whole labels map, so an
# ArgoCD-managed label would flap on every apply.
TERRAFORM_OWNED_NAMESPACES = {"external-secrets"}

ANNOTATION_CAP = 262_144

# Chart pins in *.tfvars are annotated `# renovate: helmRepo=<url> chart=<name>`
# (renovate.json's customManagers) -- reuse that as the single source of
# truth for which upstream charts Terraform installs and at what version.
RENOVATE_HELM_RE = re.compile(
    r'version\s*=\s*"([^"]+)"\s*#\s*renovate:\s*helmRepo=(\S+)\s*chart=(\S+)'
)

# Terraform-managed charts take their values from terraform/<layer>/values/
# <chart>.yaml, which this script renders with. That is the whole point of the
# file existing: the values Terraform applies and the values CI checks are the
# same bytes, so a chart bump that invalidates a key fails on the PR instead of
# at `terraform apply`.
#
# This replaced a hand-copied mirror of the values, which could not have caught
# either of the two bugs it was written after: a `ports.web.redirections` key
# the traefik schema rejects outright, and an argo-cd `server.insecure` key the
# chart silently ignores. Neither was visible while CI rendered chart defaults.
#
# <chart>.check.yaml, where present, stands in for the values Terraform builds
# at apply time from Key Vault or per-instance inputs -- so the render covers
# the whole value set rather than only the static half.
VALUES_DIRNAME = "values"
CHECK_VALUES_SUFFIX = ".check.yaml"

# Cluster-scoped kinds rendered anywhere in this repo, so dump() knows which
# resources must *not* be stamped with a namespace, and check_app_projects
# knows which half of the whitelist asymmetry a kind falls under. Getting one
# wrong is no longer cheap in both directions: a missing entry makes
# check_app_projects treat a cluster-scoped object as namespaced and skip the
# clusterResourceWhitelist check entirely, which is the check that matters.
#
# The custom kinds below are not hand-collected -- check_crd_scope asserts this
# set against the `scope:` every rendered CRD declares, so a chart bump adding a
# cluster-scoped CRD fails until it is listed here. Most are defined by a chart
# without anything in this repo instantiating one yet; they are listed against
# the day something does.
CLUSTER_SCOPED_KINDS = {
    "APIService", "ClusterCleanupPolicy", "ClusterCloudEventSource",
    "ClusterEphemeralReport", "ClusterExternalSecret", "ClusterGenerator",
    "ClusterImageCatalog", "ClusterIssuer", "ClusterPolicy",
    "ClusterPolicyReport", "ClusterPushSecret", "ClusterRole",
    "ClusterRoleBinding", "ClusterSecretStore", "ClusterTriggerAuthentication",
    "CustomResourceDefinition", "DeletingPolicy", "GeneratingPolicy",
    "GlobalContextEntry", "ImageValidatingPolicy", "IngressClass",
    "MutatingPolicy", "MutatingWebhookConfiguration", "Namespace",
    "PriorityClass", "StorageClass", "ValidatingPolicy",
    "ValidatingWebhookConfiguration",
}

# Kinds whose pod template this script knows how to reach. Kyverno's autogen
# expands the Pod-matching rules over the same set.
PODSPEC_KINDS = {
    "Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob",
}

# The AppProject rules, shared with terraform/60-argo-cd/gitops.tf rather than
# copied -- see the header of that file. The single cluster this repo deploys
# to; AppProject destinations match on server, and every registry Application
# targets the in-cluster one.
APPPROJECTS_FILE = REPO_ROOT / "terraform/60-argo-cd/appprojects.yaml"
DEST_SERVER = "https://kubernetes.default.svc"

errors: list[str] = []

# Set by --dump: where to write each rendered manifest set so the Kyverno CLI
# can run the actual policies over the same output this script inspects.
dump_dir: Path | None = None


def is_helm_test(doc: dict) -> bool:
    """A `helm.sh/hook: test` resource, which nothing here ever applies.

    ArgoCD ignores the test hook outright, and Terraform's helm_release only
    runs it on an explicit `helm test`. They are rendered by `helm template`
    all the same, and they are not held to the same standard as real workloads
    upstream -- kyverno 3.8.2 ships five test Pods on
    ghcr.io/kyverno/readiness-checker:latest. Checking them would fail CI over
    an image that never reaches the cluster.
    """
    hook = ((doc.get("metadata") or {}).get("annotations") or {}).get("helm.sh/hook", "")
    return "test" in [h.strip() for h in hook.split(",")]


def dump(docs: list[dict], source: str, namespace: str | None = None) -> None:
    """Write the rendered set out for the Kyverno CLI pass in CI.

    Test hooks are dropped here for the same reason check_images skips them:
    the CLI would deny them on disallow-latest-tag, over resources that are
    never admitted.

    `namespace` stamps metadata.namespace on namespaced resources that lack it,
    which is what ArgoCD does on apply -- a chart template only sets the field
    explicitly when it means a *different* namespace, so `helm template` output
    leaves most of them blank and the CLI would read them as `default`. Two
    policies turn on getting this right: cluster-secrets' prefix rule builds
    its expected Key Vault prefix from request.namespace, and image-supply-
    chain excludes the kyverno namespace. Only GitOps apps pass it, because
    only they have an authoritative destination namespace (the registry entry);
    the Terraform charts are rendered standalone.
    """
    if dump_dir is None:
        return
    keep = []
    for d in docs:
        if is_helm_test(d):
            continue
        if (
            namespace
            and d.get("kind") not in CLUSTER_SCOPED_KINDS
            and not (d.get("metadata") or {}).get("namespace")
        ):
            d.setdefault("metadata", {})["namespace"] = namespace
        keep.append(d)
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", source)
    (dump_dir / f"{safe}.yaml").write_text(
        yaml.safe_dump_all(keep, default_flow_style=False), encoding="utf-8"
    )

# Keep helm's repo list out of the user's HELM_REPOSITORY_CONFIG: the script
# adds one alias per pinned chart, and squatting those names in a developer's
# real config (or inheriting a stale URL from it) is a side effect a check has
# no business having.
_helm_home = tempfile.mkdtemp(prefix="check-cluster-policy-")
atexit.register(shutil.rmtree, _helm_home, True)
HELM_ENV = {
    **os.environ,
    "HELM_REPOSITORY_CONFIG": str(Path(_helm_home) / "repositories.yaml"),
    "HELM_REPOSITORY_CACHE": str(Path(_helm_home) / "cache"),
}


def run(cmd, **kw):
    # Some charts (kube-prometheus-stack's dashboard JSON) embed non-ASCII
    # bytes that the Windows default cp1252 stdout codec can't decode.
    return subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
        env=HELM_ENV, **kw
    )


def registry_of(image: str) -> str:
    """The registry an image ref resolves to, by Docker's own rule.

    The first path segment is a registry host only when the ref has more than
    one segment. A single-segment ref carrying a tag ('busybox:1.38.0') is
    docker.io/library/busybox -- reading its ':' as a host:port separator, as
    a bare `':' in head` test does, would invent a registry named after the
    image and fail it against the allow-list.
    """
    if "/" not in image:
        return "docker.io"
    head = image.split("/")[0]
    if "." in head or ":" in head or head == "localhost":
        return head
    return "docker.io"


def has_explicit_tag(image: str) -> bool:
    """Mirrors require-image-tag's `*:* | *@sha256:*`.

    Checked against the last path segment so a registry port ('host:5000/foo')
    does not read as a tag. That makes this marginally stricter than the
    Kyverno glob, which matches ':' anywhere in the ref -- strict in the
    direction that fails here rather than at admission.
    """
    return "@" in image or ":" in image.rsplit("/", 1)[-1]


def pod_spec(doc: dict):
    kind = doc.get("kind")
    if kind == "Pod":
        return doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
    if kind == "CronJob":
        return (
            ((doc.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}
        ).get("template", {}).get("spec") or {}
    return None


def load_docs(yaml_text: str, source: str) -> list[dict]:
    try:
        return [d for d in yaml.safe_load_all(yaml_text) if d]
    except yaml.YAMLError as e:
        errors.append(f"[{source}] YAML parse error: {e}")
        return []


def check_images(docs: list[dict], source: str) -> None:
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") not in PODSPEC_KINDS:
            continue
        if is_helm_test(d):
            continue
        spec = pod_spec(d)
        if not spec:
            continue
        name = (d.get("metadata") or {}).get("name", "<unnamed>")
        for key in ("containers", "initContainers", "ephemeralContainers"):
            for c in spec.get(key) or []:
                image = c.get("image", "")
                if not image:
                    continue
                reg = registry_of(image)
                if reg not in ALLOWED_REGISTRIES:
                    errors.append(
                        f"[{source}] {d['kind']}/{name}: image '{image}' resolves "
                        f"to disallowed registry '{reg}'"
                    )
                if not has_explicit_tag(image):
                    errors.append(
                        f"[{source}] {d['kind']}/{name}: image '{image}' has no "
                        f"explicit tag or digest"
                    )
                elif image.endswith(":latest"):
                    errors.append(
                        f"[{source}] {d['kind']}/{name}: image '{image}' uses the "
                        f"mutable ':latest' tag"
                    )


def check_namespaces(docs: list[dict], source: str) -> None:
    """Namespaces a chart renders for itself.

    These are the ones the app registry cannot reach: namespaceLabels only
    applies to an app's own destination namespace, so a chart that creates a
    second one (cilium-secrets) has to get its label from a chart value.
    """
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") != "Namespace":
            continue
        meta = d.get("metadata") or {}
        name = meta.get("name", "<unnamed>")
        if name in API_SERVER_NAMESPACES:
            continue
        level = (meta.get("labels") or {}).get(PSA_LABEL)
        if not level:
            errors.append(
                f"[{source}] Namespace/{name} is rendered without a {PSA_LABEL} "
                f"label -- require-namespace-psa-label denies it on CREATE and "
                f"freezes it against UPDATE"
            )
        elif level not in PSA_ALLOWED_LEVELS and name not in PSA_PRIVILEGED_NAMESPACES:
            errors.append(
                f"[{source}] Namespace/{name} is rendered with {PSA_LABEL}="
                f"'{level}' -- restrict-psa-enforce-level allows only "
                f"{'/'.join(sorted(PSA_ALLOWED_LEVELS))} outside "
                f"{sorted(PSA_PRIVILEGED_NAMESPACES)}"
            )


def check_annotation_cap(docs: list[dict], source: str, server_side_apply: bool) -> None:
    """Any object applied client-side, not only CRDs.

    The API server stores the whole object in last-applied-configuration and
    caps that annotation at 262144 bytes regardless of kind. CRDs are the usual
    way past it, not the only one -- a ConfigMap carrying a vendored dashboard
    or rule set reaches it too -- so every rendered object is measured.
    """
    for d in docs:
        if not isinstance(d, dict) or "kind" not in d:
            continue
        # Compact separators and default=str to match the Go encoder kubectl
        # serializes last-applied-configuration with: no padding, and YAML
        # scalars PyYAML resolved to dates/times rendered back as strings.
        size = len(json.dumps(d, separators=(",", ":"), default=str).encode())
        if size > ANNOTATION_CAP and not server_side_apply:
            name = d.get("metadata", {}).get("name", "<unnamed>")
            errors.append(
                f"[{source}] {d['kind']} {name} renders to {size}B, over "
                f"the {ANNOTATION_CAP}B last-applied-configuration cap, but its "
                f"bootstrap registry entry has no ServerSideApply=true"
            )


def _glob(pattern: str, val: str, allow_negation: bool = True) -> bool:
    """argo-cd pkg/apis/application/v1alpha1/app_project_types.go globMatch."""
    if allow_negation and pattern.startswith("!"):
        return not fnmatch.fnmatchcase(val, pattern[1:])
    if pattern == "*":
        return True
    return fnmatch.fnmatchcase(val, pattern)


def _destination_permitted(destinations: list[dict], namespace: str) -> bool:
    """argo-cd isDestinationMatched.

    A deny pattern returns early, so `!kube-system` beats the `*` allow no
    matter which order the two appear in. The upstream function also matches
    on destination *name*; no project here sets one, so that branch is omitted
    rather than reimplemented against nothing.
    """
    any_matched = False
    for item in destinations:
        item_ns = item.get("namespace", "")
        server_matched = _glob(item.get("server", ""), DEST_SERVER)
        ns_matched = _glob(item_ns, namespace)
        if server_matched and ns_matched:
            any_matched = True
        elif not ns_matched and item_ns.startswith("!") and server_matched:
            return False
    return any_matched


def _in_resource_list(group: str, kind: str, entries: list[dict]) -> bool:
    return any(
        _glob(e.get("group", ""), group, allow_negation=False)
        and _glob(e.get("kind", ""), kind, allow_negation=False)
        for e in entries
    )


def _group_kind_permitted(project: dict, group: str, kind: str, namespaced: bool) -> bool:
    """argo-cd IsGroupKindNamePermitted.

    The two halves are asymmetric and it is the asymmetry that bites: an absent
    namespaceResourceWhitelist permits *every* namespaced kind, while an absent
    or empty clusterResourceWhitelist permits *no* cluster-scoped kind. Neither
    default is the one a reader assumes from the other.
    """
    if namespaced:
        whitelist = project.get("namespaceResourceWhitelist")
        return whitelist is None or (
            len(whitelist) != 0 and _in_resource_list(group, kind, whitelist)
        )
    whitelist = project.get("clusterResourceWhitelist") or []
    return len(whitelist) != 0 and _in_resource_list(group, kind, whitelist)


def load_appprojects() -> dict:
    raw = yaml.safe_load(APPPROJECTS_FILE.read_text(encoding="utf-8"))
    return {
        name: {
            "destinations": proj["destinations"],
            "clusterResourceWhitelist": (
                raw["sharedClusterResources"] + proj["extraClusterResources"]
            ),
        }
        for name, proj in raw["projects"].items()
    }


def selftest_appproject_matcher(projects: dict) -> None:
    """Assert the matcher still discriminates before trusting its verdicts.

    It is a reimplementation of ArgoCD's, because ArgoCD ships no offline
    validator for this the way Kyverno ships a CLI -- so unlike the policy pass
    there is no authoritative second opinion in CI. The failure that matters is
    silent: a matcher that returns True for everything reports no findings and
    reads exactly like a clean run. These cases are the ones the live cluster
    already answered for us (documentation/programming/gitops_apps.md).
    """
    home, ks = projects["homelab"], projects["homelab-kube-system"]
    cases = [
        (_destination_permitted(home["destinations"], "monitoring"), True,
         "homelab permits an ordinary namespace"),
        (_destination_permitted(home["destinations"], "kube-system"), False,
         "homelab denies kube-system"),
        (_destination_permitted(ks["destinations"], "kube-system"), True,
         "homelab-kube-system permits kube-system"),
        (_destination_permitted(ks["destinations"], "kube-public"), False,
         "homelab-kube-system still denies kube-public"),
        (_group_kind_permitted(home, "apiregistration.k8s.io", "APIService", False), False,
         "homelab denies APIService"),
        (_group_kind_permitted(ks, "apiregistration.k8s.io", "APIService", False), True,
         "homelab-kube-system permits APIService"),
        (_group_kind_permitted(home, "apiextensions.k8s.io", "CustomResourceDefinition", False), True,
         "homelab permits CustomResourceDefinition"),
        (_group_kind_permitted(home, "", "Secret", True), True,
         "no namespaceResourceWhitelist permits every namespaced kind"),
    ]
    for got, want, what in cases:
        if got is not want:
            errors.append(
                f"[selftest] AppProject matcher is wrong: {what} returned {got}. "
                f"Every other AppProject finding this run is untrustworthy"
            )


def check_crd_scope(docs: list[dict], source: str) -> None:
    """Cross-check CLUSTER_SCOPED_KINDS against the CRDs the repo renders.

    That set is hand-maintained, and check_app_projects reads it to decide
    which half of the asymmetry above applies to a kind. A custom kind missing
    from it is treated as namespaced, which silently skips the whitelist check
    that is the entire point. Every CRD states its own scope, so for custom
    kinds the answer is in the rendered output rather than in the set.
    """
    for d in docs:
        if d.get("kind") != "CustomResourceDefinition":
            continue
        spec = d.get("spec") or {}
        kind = (spec.get("names") or {}).get("kind")
        if not kind:
            continue
        is_cluster = spec.get("scope") == "Cluster"
        if is_cluster and kind not in CLUSTER_SCOPED_KINDS:
            errors.append(
                f"[{source}] CRD {d['metadata']['name']} declares scope: Cluster, "
                f"but '{kind}' is missing from CLUSTER_SCOPED_KINDS -- "
                f"check_app_projects would check it as if it were namespaced"
            )
        elif not is_cluster and kind in CLUSTER_SCOPED_KINDS:
            errors.append(
                f"[{source}] CRD {d['metadata']['name']} declares scope: "
                f"{spec.get('scope')}, but '{kind}' is listed in "
                f"CLUSTER_SCOPED_KINDS -- dump() would leave it unstamped"
            )


def check_app_projects(docs: list[dict], app: dict, projects: dict) -> None:
    """Replay ArgoCD's per-object project check over what the app renders.

    ArgoCD validates every object a chart produces, not just the Application's
    spec.destination (controller/sync.go validateSyncPermissions): each
    object's own metadata.namespace against the project destinations, its
    group/kind against the whitelists. A chart quietly writing one RoleBinding
    into kube-system fails the sync, and because a wave applies only once the
    one before it is healthy, it takes every later wave down with it. Catching
    it here costs a red PR instead.
    """
    name = app.get("project", "homelab")
    project = projects.get(name)
    if project is None:
        errors.append(
            f"[registry:{app['name']}] names project '{name}', which is not in "
            f"{APPPROJECTS_FILE.relative_to(REPO_ROOT)} -- an Application whose "
            f"project does not exist goes to an error state"
        )
        return

    for d in docs:
        if is_helm_test(d):
            continue
        kind = d.get("kind")
        group = d.get("apiVersion", "").rpartition("/")[0]
        namespaced = kind not in CLUSTER_SCOPED_KINDS
        meta = d.get("metadata") or {}

        if not _group_kind_permitted(project, group, kind, namespaced):
            errors.append(
                f"[{app['name']}] {group or '(core)'}/{kind} '{meta.get('name')}' is not "
                f"permitted in project '{name}' -- add it to "
                f"{'extraClusterResources' if not namespaced else 'namespaceResourceWhitelist'} "
                f"in {APPPROJECTS_FILE.relative_to(REPO_ROOT)}"
            )
            continue

        if not namespaced:
            continue
        # Same defaulting ArgoCD applies: an object that names no namespace
        # lands in the Application's destination. dump() stamps this too, but
        # only under --dump, so it is recomputed rather than relied on.
        namespace = meta.get("namespace") or app["namespace"]
        if not _destination_permitted(project["destinations"], namespace):
            errors.append(
                f"[{app['name']}] {kind} '{meta.get('name')}' renders into namespace "
                f"'{namespace}', which project '{name}' denies -- the chart writes "
                f"outside its destination namespace ('{app['namespace']}')"
            )


def check_registry_namespaces(registry: dict) -> None:
    """The destination namespaces, which ArgoCD creates rather than a chart.

    They carry their PSA label through managedNamespaceMetadata, which the
    bootstrap template renders only from namespaceLabels -- so an app owning a
    namespace without them produces an unlabelled namespace at sync time, and
    nothing in the rendered output would show it.
    """
    for app in registry["apps"]:
        if not app.get("createNamespace"):
            continue
        if app["namespace"] in TERRAFORM_OWNED_NAMESPACES:
            continue
        level = (app.get("namespaceLabels") or {}).get(PSA_LABEL)
        if not level:
            errors.append(
                f"[registry:{app['name']}] owns namespace '{app['namespace']}' "
                f"(createNamespace: true) but sets no {PSA_LABEL} in "
                f"namespaceLabels -- ArgoCD would create it unlabelled"
            )
        elif (
            level not in PSA_ALLOWED_LEVELS
            and app["namespace"] not in PSA_PRIVILEGED_NAMESPACES
        ):
            errors.append(
                f"[registry:{app['name']}] sets {PSA_LABEL}='{level}' on "
                f"namespace '{app['namespace']}' -- restrict-psa-enforce-level "
                f"allows only {'/'.join(sorted(PSA_ALLOWED_LEVELS))} outside "
                f"{sorted(PSA_PRIVILEGED_NAMESPACES)}, so ArgoCD would be denied "
                f"when it creates or updates the namespace"
            )


def render_gitops_apps() -> None:
    registry = yaml.safe_load((REPO_ROOT / "kubernetes/bootstrap/values.yaml").read_text())
    check_registry_namespaces(registry)
    projects = load_appprojects()
    selftest_appproject_matcher(projects)

    for app in registry["apps"]:
        path = REPO_ROOT / "kubernetes/apps" / app["group"] / app["name"]
        chart_yaml = path / "Chart.yaml"
        if not chart_yaml.exists():
            errors.append(
                f"[{app['name']}] registry entry points at {path.relative_to(REPO_ROOT)}, "
                f"which has no Chart.yaml"
            )
            continue

        built_deps = False
        if "dependencies" in chart_yaml.read_text():
            r = run(["helm", "dependency", "build", str(path)])
            built_deps = True
            if r.returncode != 0:
                errors.append(f"[{app['name']}] helm dependency build failed: {r.stderr.strip()}")
                continue

        cmd = ["helm", "template", app["name"], str(path), "--include-crds",
               "--namespace", app["namespace"]]
        if app.get("needsDomain"):
            cmd += ["--set", "global.domain=example.com"]
        if app.get("needsTenant"):
            cmd += ["--set", "global.tenantId=00000000-0000-0000-0000-000000000000"]
        if app.get("needsVaultUrl"):
            cmd += ["--set", "vaultUrl=https://example.vault.azure.net/"]

        r = run(cmd)

        if built_deps:
            shutil.rmtree(path / "charts", ignore_errors=True)
            (path / "Chart.lock").unlink(missing_ok=True)

        if r.returncode != 0:
            errors.append(f"[{app['name']}] helm template failed: {r.stderr.strip()}")
            continue

        docs = load_docs(r.stdout, app["name"])
        dump(docs, app["name"], namespace=app["namespace"])
        ssa = "ServerSideApply=true" in (app.get("extraSyncOptions") or [])
        # The kyverno app is checked like any other, even though the cluster's
        # image rules exclude its whole namespace. That exclusion covers the
        # chart's :latest test hooks, which is_helm_test already drops here --
        # so mirroring the namespace exclusion on top of it would only hide
        # the images ArgoCD really does apply from that chart.
        check_images(docs, app["name"])
        check_namespaces(docs, app["name"])
        check_annotation_cap(docs, app["name"], ssa)
        check_crd_scope(docs, app["name"])
        check_app_projects(docs, app, projects)


def terraform_values_files(layer: Path, chart: str) -> list[Path]:
    """The values Terraform passes this chart, if the layer keeps them in a file.

    Convention over registry: terraform/<layer>/values/<chart>.yaml is read by
    the layer's helm_release and by this function, so there is nothing to keep
    in sync. A chart with no such file is rendered with its defaults, which is
    correct for the ones Terraform genuinely installs unconfigured.
    """
    found = []
    for name in (f"{chart}.yaml", f"{chart}{CHECK_VALUES_SUFFIX}"):
        path = layer / VALUES_DIRNAME / name
        if path.exists():
            found.append(path)
    return found


def check_orphaned_values_files(used: set[Path]) -> None:
    """A values file no pinned chart renders is a file nothing checks.

    It happens the obvious way: a chart pin is renamed or removed from tfvars
    and its values file is left behind. The file keeps being read by the
    layer's helm_release -- or worse, stops being read and nobody notices --
    while this script silently skips it.
    """
    for layer in sorted(REPO_ROOT.glob("terraform/*/")):
        for path in sorted((layer / VALUES_DIRNAME).glob("*.yaml")):
            if path in used:
                continue
            errors.append(
                f"[values] {path.relative_to(REPO_ROOT)} matches no chart pinned in "
                f"{layer.name}/terraform.tfvars -- either the pin lost its "
                f"`# renovate: helmRepo=... chart=...` annotation or the file is dead"
            )


def render_terraform_charts() -> None:
    seen_charts: set[str] = set()
    used_values: set[Path] = set()
    for tfvars in sorted(REPO_ROOT.glob("terraform/*/terraform.tfvars")):
        text = tfvars.read_text()
        layer = tfvars.parent
        for version, repo_url, chart in RENOVATE_HELM_RE.findall(text):
            source = f"terraform:{chart}@{version}"
            # One alias per chart, not per repo URL: keying the alias off the
            # URL leaves a second chart from the same repo without one, and
            # `helm template <chart> <chart>/<chart>` then fails on a missing
            # repo rather than on anything to do with policy.
            if chart not in seen_charts:
                for step in (["repo", "add", "--force-update", chart, repo_url],
                             ["repo", "update", chart]):
                    r = run(["helm", *step])
                    if r.returncode != 0:
                        errors.append(f"[{source}] helm {' '.join(step)} failed: {r.stderr.strip()}")
                        break
                else:
                    seen_charts.add(chart)
                if chart not in seen_charts:
                    continue

            cmd = ["helm", "template", chart, f"{chart}/{chart}", "--version", version,
                   "--include-crds"]
            for vf in terraform_values_files(layer, chart):
                used_values.add(vf)
                cmd += ["-f", str(vf)]
            r = run(cmd)
            if r.returncode != 0:
                # A schema rejection lands here. Charts that ship a
                # values.schema.json (traefik does) refuse an unknown key
                # outright, and the helm provider validates through the same
                # code path -- so this failure is the apply failing, found
                # early.
                errors.append(f"[{source}] helm template failed: {r.stderr.strip()}")
                continue

            docs = load_docs(r.stdout, source)
            dump(docs, source)
            check_images(docs, source)
            check_namespaces(docs, source)
            # Terraform applies these via helm_release (server-side by
            # default in the helm provider), not client kubectl apply, so
            # the annotation-size cap that gates GitOps apps doesn't apply.
            check_annotation_cap(docs, source, server_side_apply=True)

    check_orphaned_values_files(used_values)


def check_vendored_manifests() -> None:
    # Multus/whereabouts (terraform/40-kube-networking/manifests) have no
    # helm chart upstream -- plain manifests, checked as rendered.
    manifests_dir = REPO_ROOT / "terraform/40-kube-networking/manifests"
    for f in sorted(manifests_dir.glob("*.yaml")):
        docs = load_docs(f.read_text(), f"vendored:{f.name}")
        dump(docs, f"vendored:{f.name}")
        check_images(docs, f"vendored:{f.name}")
        check_namespaces(docs, f"vendored:{f.name}")


def main() -> None:
    global dump_dir

    if not shutil.which("helm"):
        sys.exit("helm required: https://helm.sh/docs/intro/install/")

    argv = sys.argv[1:]
    if argv[:1] == ["--dump"]:
        if len(argv) != 2:
            sys.exit("usage: check_cluster_policy.py [--dump <dir>]")
        dump_dir = Path(argv[1])
        dump_dir.mkdir(parents=True, exist_ok=True)
    elif argv:
        sys.exit("usage: check_cluster_policy.py [--dump <dir>]")

    render_gitops_apps()
    render_terraform_charts()
    check_vendored_manifests()

    if dump_dir is not None:
        print(f"Rendered manifests written to {dump_dir}/\n")

    if errors:
        print(f"FAILED -- {len(errors)} issue(s):\n")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)

    print(
        "OK -- all rendered images, namespaces and objects are within policy, "
        "and within the AppProject each app names."
    )


if __name__ == "__main__":
    main()
