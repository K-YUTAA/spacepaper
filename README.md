# SpacePaper

Macのモニターと仮想デスクトップ（Spaces）に、それぞれ異なる壁紙を自動で割り当てるメニューバーアプリです。

モニターをつなぎ替えたりデスクトップを増やしたりして同じ壁紙が引き継がれても、表示したときに重複を補正します。静止画の管理に絞り、壁紙が正しい場合は再設定しません。

現在の配布版は **v1.1.0の試用ビルド**です。Developer ID署名・Appleの公証は未実施です。Intelを含むUniversalバイナリですが、実機確認はApple SiliconのmacOS 27.2で行っています。

## Homebrewからインストール

```sh
brew install --cask K-YUTAA/tap/spacepaper
open -a SpacePaper
```

- macOS 14 Sonoma以降
- Apple Silicon／Intel共通のUniversalアプリ
- 実行時に別のアプリやPythonをインストールする必要はありません

アプリは標準で`/Applications/SpacePaper.app`へ配置されます。手動で入れる場合は[Releases](https://github.com/K-YUTAA/spacepaper/releases)のZIPを展開してApplicationsへ移動してください。

公証していないため、初回起動をmacOSが制限する場合があります。[Appleの案内](https://support.apple.com/ja-jp/102445)に従って判断してください。

## 最初の設定

1. SpacePaperを起動します。Dockには常駐せず、メニューバーに写真が重なったアイコンが表示されます。
2. アイコンをクリックし、**「画像フォルダを選び直す…」**から使いたいフォルダを選びます。
3. 毎回自動で起動したい場合は、**「ログイン時に起動」**をオンにします。

登録フォルダのサブフォルダも対象です。JPEG、PNG、HEIC、TIFF、WebP、AVIFなど、macOSで読み込める静止画を使えます。HEIC等は静止画へ変換してアプリの保存先にコピーします。元ファイルは変更しません。

初回にフォルダを指定していない場合は、読み取れる現在の壁紙とMac標準の静止画を候補にします。Mac標準の画像を混ぜたくない場合は、メニューの「Mac標準の画像も使う」をオフにしてください。

## 動作

- 接続中のすべての画面・通常デスクトップに異なる画像を予約します。
- 新しいデスクトップは、初めて開いたときに反映します。裏にあるデスクトップを強制的に切り替えません。
- モニターの追加・再接続・配置変更・スリープ復帰でも再確認します。
- 通知を取りこぼした場合に備え、約15秒ごとに確認します。省電力機構や画面の状態によって遅れる場合があります。
- 画像フォルダへ増やした画像は約2分以内に取り込みます。
- 同じ画像のコピーは正規化したピクセルでまとめます。似ている別画像まで除外する仕組みではありません。
- 正しく表示されている壁紙を優先して保持します。
- フォルダを一時的に読めない場合は、予約と壁紙を保って待機します。

切り替え直後は、macOSが引き継いだ同じ壁紙が一時的に見えることがあります。アプリ専用のフルスクリーンSpaceは対象外です。画像がデスクトップ数より少ない場合は不足をメニューに表示し、不足分を使い回しません。

## メニュー

| 項目 | 操作 |
| --- | --- |
| 今すぐ重複を確認 | 候補フォルダと割り当てを再確認 |
| 自動変更を一時停止／再開 | 変更を停止・再開。一時停止状態は再起動後も維持 |
| 画像フォルダを選び直す… | そのフォルダだけを候補に変更 |
| 画像フォルダを追加… | 複数フォルダを候補に追加 |
| 登録したフォルダ | 指定フォルダを候補から外す |
| Mac標準の画像も使う | 標準画像の利用を切り替え |
| ログイン時に起動 | 次回ログイン時の自動起動を切り替え |
| 状態・ログを開く | 設定・状態記録の保存先を開く |
| SpacePaperを終了 | 現在の壁紙を保って終了 |

ログイン時の起動の希望は設定へ保存し、Homebrew更新後にアプリを開くと現在のインストール先で登録し直します。新規インストールでは自動起動を勝手に有効にしません。

## 更新とアンインストール

```sh
brew update
brew upgrade --cask K-YUTAA/tap/spacepaper
open -a SpacePaper
```

```sh
brew uninstall --cask K-YUTAA/tap/spacepaper
```

アンインストール時はアプリと自動起動ジョブを停止します。画像・設定・壁紙のバックアップは保持します。終了やアンインストールで、以前の壁紙へ自動復元する機能はありません。

## 保存先

`~/Library/Application Support/SpacePaper/`

| 保存物 | 内容 |
| --- | --- |
| `state.json` | 登録フォルダ、割り当て、一時停止、自動起動の希望 |
| `Images/` | アプリが取り込んだ静止画 |
| `Before/Index.plist` | 最初に壁紙を変える直前のmacOS壁紙設定のバックアップ |
| `status.json` | 画面数・候補数・表示画像と予約の照合結果 |
| `events.log` | 壁紙変更と異常の記録。約1MBでローテーション |
| `instance.json` / `command.json` / `Replies/` | CLI操作とその応答 |

macOSの壁紙設定ストアは直接書き換えません。バックアップを確認できない場合は壁紙の変更を待機します。削除されたSpaceの予約は整理し、切断した画面の予約は最長30日保持します。

自動起動ジョブは`~/Library/LaunchAgents/local.kitano.spacepaper.plist`です。

## CLI

Homebrew版は`spacepaper`コマンドも利用できます。

```sh
spacepaper --status
spacepaper --diagnose
spacepaper --use-folder ~/Pictures/Wallpapers
spacepaper --reconcile
spacepaper --pause
spacepaper --resume
spacepaper --quit
```

`--use-folder`の相対パスは、CLIを実行した場所を基準に解決します。停止中のアプリへ操作を予約しません。操作は発行先の起動インスタンスと15秒の期限で検証し、タイムアウトした未処理コマンドは削除します。

## 実装と確認範囲

Swift + AppKit、外部パッケージ依存なし。画像の読み込み・変換・比較はバックグラウンドキュー、画面情報の取得と壁紙設定はメインスレッドで行います。壁紙変更はAppleの`NSWorkspace.setDesktopImageURL`を使います。

Spaceの一覧取得にはSkyLightの非公開関数を読み取り専用で利用するため、macOSの更新で互換性が変わる可能性があります。取得結果の検証に失敗した場合は変更を待機します。SIPの変更、画面収録権限、アクセシビリティ操作は使用しません。

Apple Silicon、3画面構成で、壁紙設定の重複補正・停止／再開・起動・導入スクリプトを確認しました。割り当てとコマンド処理等の自動テストは21件です。Intel実機、物理的なモニター抜き差し、スリープ復帰、長時間運用は未検証です。詳しくは[検証記録](VALIDATION.md)を参照してください。

## ソースからビルド

Xcodeまたは対応するCommand Line ToolsとSwiftが必要です。

```sh
git clone https://github.com/K-YUTAA/spacepaper.git
cd spacepaper
swift test --disable-sandbox
./scripts/build.sh
./scripts/package.sh
```

`build.sh`は実行中のMac向け、`package.sh`はApple Silicon／Intel共通のZIPと`SHA256SUMS`を`dist/`に作ります。署名はアドホック署名です。

`./scripts/install.sh`はソースからビルドしたアプリを`~/Applications`へ入れる開発用スクリプトです。既存のアプリをバックアップして更新し、自動起動をオフにしていた場合はその設定を維持します。Homebrew管理のアプリを使う場合は上のHomebrew手順を使ってください。

`--disable-sandbox`はSwiftPMのビルド用子プロセスに対する追加サンドボックスだけの指定です。macOSのSIPやアプリ権限を変更しません。
