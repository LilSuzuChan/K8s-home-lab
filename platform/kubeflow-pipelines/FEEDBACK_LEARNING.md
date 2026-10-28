# Drawing Classifierの継続学習

app/networkpolicy.yaml に、Kubeflowから drawing-classifier Namespaceの feedback-api:8080 へのegressを追加しています。既存のDNS・オブジェクトストレージ・Kubernetes APIの許可は維持します。

```bash
kubectl apply -f platform/kubeflow-pipelines/app/networkpolicy.yaml
```

アプリ、PVC、受信NetworkPolicyはdrawing-classifierリポジトリのk8s/で管理します。同リポジトリのCONTINUOUS_LEARNING.mdとops/deploy.pyで新しいイメージdigestを指定して導入してください。共有トークンSecret drawing-feedback はアプリとKubeflowの両Namespaceに作成され、KFPのSnapshot/Promoteステップだけに注入されます。既存ghcr-pullもKubeflowへ同期し、各タスクから参照します。PVCは既定値のないクラスタに合わせlocal-pathを明示します。Secret本体をGitに保存しないでください。

03:00 JSTの日次Recurring Runは並列1で、MNIST精度とフィードバック評価の比較に合格したONNXだけを配信します。KFPの既存pipeline-runner ServiceAccountを使用し、追加のクラスタ権限やDeploymentのpatch権限は不要です。パイプラインのモデル配信はAPIへの認証付きHTTP要求で行います。
