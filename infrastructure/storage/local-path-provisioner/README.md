# Local Path Provisioner

[rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) **v0.0.37** を使い、
PVC からノードローカルの PersistentVolume を動的に作成する。

> **注意: これは共有ストレージでも高可用ストレージでもない。**
> データは PV を作成したノード 1 台のディスクにだけ存在し、レプリケーションも ReadWriteMany もない。

## 導入した理由

- クラスターに StorageClass が無く、PVC を使うアプリ (将来の Kubeflow Pipelines / MLflow / MinIO など) を動かせなかった。
- シングルノード構成では、追加コンポーネントの少ない Local Path Provisioner が最小構成で済む。
- 上流の YAML とイメージは amd64 / arm64 のマルチアーキテクチャ対応で、Raspberry Pi を追加しても同じマニフェストを使える。

## StorageClass / PV / PVC の関係

```text
PVC (storageClassName: local-path, 1Gi)   ← アプリが「この容量が欲しい」と要求する
  │  Pod がスケジュールされる (WaitForFirstConsumer)
  ▼
StorageClass local-path                     ← 「誰がどう作るか」の定義 (provisioner: rancher.io/local-path)
  │  local-path-provisioner が helper Pod を起動してディレクトリを作成
  ▼
PV (hostPath, nodeAffinity: そのノード)      ← 実体: /var/mnt/local-path-provisioner/<pv>_<ns>_<pvc>
```

- `volumeBindingMode: WaitForFirstConsumer`: PVC を使う Pod の配置先ノードが決まってから、そのノードに PV を作る。
  PVC 単体では `Pending` のままなのが正常。
- **デフォルト StorageClass にはしていない。** PVC で `storageClassName: local-path` を必ず明示する。
  指定の無い PVC は Pending のままになる (Kubeflow Pipelines 等の導入時に再検討する)。
- 容量 (`resources.requests.storage`) は**制限されない**。ディレクトリなので、実際には EPHEMERAL の空きまで書き込める。

## reclaimPolicy: Delete のリスク

`local-path` は上流のまま `reclaimPolicy: Delete`。

- **PVC を削除すると、PV とノード上のデータディレクトリが自動で `rm -rf` される。** 復元手段はない。
- PVC は次の操作でも削除される: `kubectl delete ns <ns>`、`kubectl delete -k`、`helm uninstall`
  (チャートが PVC を管理している場合)、StatefulSet の `persistentVolumeClaimRetentionPolicy: Delete`。
- 重要なデータを置く段階では、バックアップ方針と `Retain` の StorageClass を含めて再設計すること
  (現時点では `local-path-retain` は用意していない)。

## Talos Linux での保存先

| 項目 | 値 |
|---|---|
| ノード上のパス | `/var/mnt/local-path-provisioner` |
| 実体 | Talos の `UserVolumeConfig` (`volumeType: directory`)。EPHEMERAL パーティション (`/dev/sda4`, xfs, `/var`) 上のディレクトリ |
| Talos 側の設定 | [`talos/patches/user-volume-local-path.yaml`](../../../talos/patches/user-volume-local-path.yaml) |

- Talos はイミュータブル OS のため、書き込み可能で永続するのは `/var` 配下だけ。
  `/var/mnt/<name>` はユーザーボリュームのマウント先で、kubelet コンテナにも自動で伝播される。
- `volumeType: directory` はパーティション作成・フォーマットを行わない。容量は EPHEMERAL と共有で、
  ファイルシステムレベルの分離・上限は無い (EPHEMERAL が満杯になると kubelet やコンテナログにも影響する)。
- 上流の既定値 `/opt/local-path-provisioner` や K3s の `/var/lib/rancher/k3s/storage` は Talos 向けではないので使わない。
- Talos v1.13.9 の `UserVolumeConfig` で `volumeType: directory` がサポートされていることは、
  ソース (`pkg/machinery/config/types/block/user_volume_config.go`) とドキュメントで確認済み。

### 再起動・アップグレード時の永続性

| 操作 | データ |
|---|---|
| ノード再起動 | 保持される (EPHEMERAL は永続) |
| `talosctl upgrade` | 保持される (v1.13 の upgrade は EPHEMERAL を消去しない) |
| `UserVolumeConfig` の削除 | マウントは外れるが、ディレクトリのデータは残る (再適用で復帰) |
| `talosctl reset` (既定の wipe-mode all / EPHEMERAL を含む) | **消える** |
| 再インストール・ディスク初期化 | **消える** |

## 導入コマンド

前提: `TALOSCONFIG=talos/talosconfig`、kubeconfig がこのクラスターを向いていること。

```sh
# 1. Talos にユーザーボリュームを追加 (まず差分だけ確認)
talosctl -n 192.168.100.20 -e 192.168.100.20 patch mc \
  --patch @talos/patches/user-volume-local-path.yaml --mode no-reboot --dry-run
talosctl -n 192.168.100.20 -e 192.168.100.20 patch mc \
  --patch @talos/patches/user-volume-local-path.yaml --mode no-reboot
talosctl -n 192.168.100.20 -e 192.168.100.20 get volumestatus u-local-path-provisioner
talosctl -n 192.168.100.20 -e 192.168.100.20 get mountstatus | grep local-path

# 2. Local Path Provisioner
kubectl diff -k infrastructure/storage/local-path-provisioner/
kubectl apply -k infrastructure/storage/local-path-provisioner/
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
kubectl get storageclass local-path
```

`--mode no-reboot` は、再起動が必要な変更だった場合に適用せず失敗する (意図しない再起動を防ぐ)。

## 検証コマンド

```sh
T=infrastructure/storage/local-path-provisioner/test
kubectl apply -k $T
kubectl -n storage-test get pvc,pod          # Pod 作成後に PVC が Bound になる
kubectl -n storage-test wait --for=condition=Ready pod/storage-test --timeout=120s
kubectl -n storage-test logs storage-test    # created-at の時刻
kubectl get pv -o wide

# Pod を再作成しても created-at が変わらないこと
kubectl -n storage-test exec storage-test -- cat /data/created-at /data/boot.log
kubectl -n storage-test delete pod storage-test
kubectl apply -k $T
kubectl -n storage-test wait --for=condition=Ready pod/storage-test --timeout=120s
kubectl -n storage-test exec storage-test -- cat /data/created-at /data/boot.log

# ノード上のディレクトリ
talosctl -n 192.168.100.20 -e 192.168.100.20 ls /var/mnt/local-path-provisioner
```

### テストの削除

```sh
kubectl delete -k infrastructure/storage/local-path-provisioner/test/
kubectl get pv                                   # reclaimPolicy: Delete により PV も消える
talosctl -n 192.168.100.20 -e 192.168.100.20 ls /var/mnt/local-path-provisioner   # ディレクトリも消える
```

## トラブルシューティング

| 症状 | 確認 |
|---|---|
| PVC が `Pending` のまま | Pod が無いだけなら正常 (WaitForFirstConsumer)。`kubectl describe pvc` の Events、`storageClassName: local-path` の指定漏れ |
| PV が作られない | `kubectl -n local-path-storage logs deploy/local-path-provisioner` |
| helper Pod が作れない (`violates PodSecurity`) | `kubectl get ns local-path-storage --show-labels` に `pod-security.kubernetes.io/enforce=privileged` があるか |
| helper Pod が失敗する / パスが無い | `talosctl get volumestatus u-local-path-provisioner`、`talosctl get mountstatus`、`talosctl ls /var/mnt` |
| 書き込みで `Permission denied` | ディレクトリは `0777` で作成される。アプリの `fsGroup`/`runAsUser` と既存ファイルの所有者を確認 |
| 容量不足 | `talosctl -n 192.168.100.20 -e 192.168.100.20 mounts` で `/var` の空き。容量制限は効かない点に注意 |

## バックアップの注意点

- このストレージ自体にスナップショットやバックアップ機能は無い。ディスク故障・`talosctl reset` で失われる。
- 重要データはアプリ側の機能 (DB ダンプ、MinIO のレプリケーション/ミラー等) でクラスター外へ退避すること。
- Talos では SSH できないため、ノードのディレクトリを直接 rsync する手段は無い。
  必要な場合は対象 PVC をマウントしたバックアップ用 Pod から外部へ転送する
  (`talosctl copy` でも取得できるが、稼働中データの整合性は保証されない)。

## マルチノード化した際の制約

- PV には作成ノードの `nodeAffinity` が付く。**そのノードが停止すると、PVC を使う Pod は他ノードで起動できない。**
- 新しいノード (例: Raspberry Pi 4 の worker) でも使うには、そのノードの machine config にも
  `talos/patches/user-volume-local-path.yaml` を適用する (worker 用の設定にも含める)。
  ConfigMap の `DEFAULT_PATH_FOR_NON_LISTED_NODES` が全ノードに適用される。
- Raspberry Pi で使う場合、SD カードは書き込み耐久性が低いので USB SSD を推奨。
- ノード間で共有したい・ノード障害に耐えたい場合は、Longhorn / NFS / Rook-Ceph など別のストレージが必要。

## ファイル構成

```text
infrastructure/storage/local-path-provisioner/
├── kustomization.yaml
├── upstream/local-path-storage-v0.0.37.yaml   # 上流 deploy/local-path-storage.yaml (無改変)
├── patches/
│   ├── namespace-pod-security.yaml            # local-path-storage namespace のみ enforce: privileged
│   └── config.yaml                            # 保存先 /var/mnt/local-path-provisioner, helper イメージ busybox:1.37.0
└── test/                                      # 動作確認用 (本体とは別に apply / delete)
```

上流ファイルの検証: `sha256sum upstream/local-path-storage-v0.0.37.yaml` が
`9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65` であること
(<https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml> と一致)。

### アップグレード手順 (将来)

1. 新しいリリースの `deploy/local-path-storage.yaml` を `upstream/local-path-storage-<ver>.yaml` として追加し、sha256 を記録。
2. `kustomization.yaml` の参照先を変更し、上流 ConfigMap の `helperPod.yaml` に変更が無いか確認して `patches/config.yaml` に反映。
3. `kubectl diff -k` で差分を確認してから適用。
