import Foundation

fileprivate func tr(en: @autoclosure () -> String, ko: @autoclosure () -> String, ja: @autoclosure () -> String) -> String {
    switch LocalizationCenter.shared.language {
    case .en:
        return en()
    case .ko:
        return ko()
    case .ja:
        return ja()
    }
}

enum L10n {
    static var appName: String { "Sukurini" }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let value = max(1, Int(seconds.rounded()))
            return tr(en: "\(value)s", ko: "\(value)초", ja: "\(value)秒")
        }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return tr(en: "\(minutes) min", ko: "\(minutes)분", ja: "\(minutes)分")
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return tr(en: "\(hours)h \(rest)m", ko: "\(hours)시간 \(rest)분", ja: "\(hours)時間\(rest)分")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    static func megabytes(_ value: Int64) -> String {
        String(format: "%.0f MB", Double(value) / 1_048_576.0)
    }
}

extension L10n {
    enum Common {
        static var ok: String { tr(en: "OK", ko: "확인", ja: "OK") }
        static var cancel: String { tr(en: "Cancel", ko: "취소", ja: "キャンセル") }
        static var stop: String { tr(en: "Stop", ko: "중지", ja: "停止") }
        static var save: String { tr(en: "Save", ko: "저장", ja: "保存") }
        static var revert: String { tr(en: "Revert", ko: "되돌리기", ja: "元に戻す") }
        static var clear: String { tr(en: "Clear", ko: "지우기", ja: "消去") }
        static var remove: String { tr(en: "Remove", ko: "삭제", ja: "削除") }
        static var retry: String { tr(en: "Retry", ko: "다시 시도", ja: "再試行") }
        static var convert: String { tr(en: "Convert", ko: "변환", ja: "変換") }
        static var organize: String { tr(en: "Organize", ko: "정리", ja: "整理") }
        static var none: String { tr(en: "None", ko: "없음", ja: "なし") }
        static var off: String { tr(en: "Off", ko: "꺼짐", ja: "オフ") }
        static var counting: String { tr(en: "Counting…", ko: "세는 중…", ja: "数えています…") }
        static var missing: String { tr(en: "Missing", ko: "없음", ja: "見つかりません") }
        static var dash: String { "—" }
    }
}

extension L10n {
    enum Menu {
        static var preferences: String { tr(en: "Preferences…", ko: "설정…", ja: "設定…") }
        static var folders: String { tr(en: "Folders", ko: "폴더", ja: "フォルダ") }
        static var setupGuide: String { tr(en: "Setup Guide…", ko: "설정 가이드…", ja: "セットアップガイド…") }
        static var checkForUpdates: String { tr(en: "Check for Updates…", ko: "업데이트 확인…", ja: "アップデートを確認…") }
        static var about: String { tr(en: "About Sukurini", ko: "Sukurini 정보", ja: "Sukurini について") }
        static var quit: String { tr(en: "Quit Sukurini", ko: "Sukurini 종료", ja: "Sukurini を終了") }
        static var noFolders: String { tr(en: "No folders", ko: "폴더 없음", ja: "フォルダなし") }
        static var addFolder: String { tr(en: "Add Folder…", ko: "폴더 추가…", ja: "フォルダを追加…") }

        static func folderMissing(_ name: String) -> String {
            tr(en: "\(name) (missing)", ko: "\(name) (없음)", ja: "\(name)（見つかりません）")
        }

        static var watchFolderPrompt: String { tr(en: "Watch Folder", ko: "폴더 감시", ja: "フォルダを監視") }
        static var watchFolderMessage: String {
            tr(
                en: "Choose a folder for Sukurini to watch",
                ko: "Sukurini가 지켜볼 폴더를 골라 주세요",
                ja: "Sukurini が見張るフォルダを選んでください"
            )
        }

        static var aboutTagline: String {
            tr(
                en: "A modern rebuild of Screenie, for Apple Silicon",
                ko: "Apple Silicon을 위해 새로 만든 Screenie",
                ja: "Apple Silicon 向けに作り直した Screenie"
            )
        }

        static var edit: String { tr(en: "Edit", ko: "편집", ja: "編集") }
        static var undo: String { tr(en: "Undo", ko: "실행 취소", ja: "取り消す") }
        static var redo: String { tr(en: "Redo", ko: "실행 복귀", ja: "やり直す") }
        static var cut: String { tr(en: "Cut", ko: "오려두기", ja: "カット") }
        static var copy: String { tr(en: "Copy", ko: "복사하기", ja: "コピー") }
        static var paste: String { tr(en: "Paste", ko: "붙여넣기", ja: "ペースト") }
        static var selectAll: String { tr(en: "Select All", ko: "전체 선택", ja: "すべてを選択") }
        static var window: String { tr(en: "Window", ko: "윈도우", ja: "ウインドウ") }
        static var close: String { tr(en: "Close", ko: "닫기", ja: "閉じる") }

        static var screenieTitle: String {
            tr(en: "Screenie is running", ko: "Screenie가 실행 중이에요", ja: "Screenie が実行中です")
        }
        static var screenieBody: String {
            tr(
                en: "Sukurini replaces Screenie. Running both means two menu bar icons and duplicated OCR work. Quitting Screenie is recommended.",
                ko: "Sukurini가 Screenie를 대신해요. 둘 다 켜 두면 메뉴 막대 아이콘이 두 개가 되고 글자 인식도 두 번 돌아가요. Screenie는 꺼 두는 걸 권해요.",
                ja: "Sukurini は Screenie の代わりになります。両方動かすとメニューバーのアイコンが 2 つになり、文字認識も二重に走ります。Screenie は終了することをおすすめします。"
            )
        }
    }
}

extension L10n {
    enum Window {
        static var preferences: String { tr(en: "Sukurini Settings", ko: "Sukurini 설정", ja: "Sukurini の設定") }
        static var onboarding: String { tr(en: "Welcome to Sukurini", ko: "Sukurini에 오신 걸 환영해요", ja: "Sukurini へようこそ") }
    }
}

extension L10n {
    enum Tabs {
        static var general: String { tr(en: "General", ko: "일반", ja: "一般") }
        static var folders: String { tr(en: "Folders", ko: "폴더", ja: "フォルダ") }
        static var images: String { tr(en: "Images", ko: "이미지", ja: "画像") }
        static var search: String { tr(en: "Search", ko: "검색", ja: "検索") }
    }
}

extension L10n {
    enum Language {
        static var header: String { tr(en: "Language", ko: "언어", ja: "言語") }
        static var label: String { tr(en: "Display language", ko: "표시 언어", ja: "表示言語") }
        static var footer: String {
            tr(
                en: "Applies right away, no restart needed.",
                ko: "고르면 바로 적용돼요. 앱을 다시 켜지 않아도 돼요.",
                ja: "選ぶとすぐ反映されます。アプリを再起動する必要はありません。"
            )
        }

        static func systemOption(_ resolved: ResolvedLanguage) -> String {
            tr(
                en: "System (\(resolved.nativeName))",
                ko: "시스템 설정 (\(resolved.nativeName))",
                ja: "システム設定（\(resolved.nativeName)）"
            )
        }
    }
}

extension L10n {
    enum Startup {
        static var header: String { tr(en: "Startup", ko: "시작", ja: "起動") }
        static var launchAtLogin: String {
            tr(en: "Launch Sukurini at login", ko: "로그인할 때 Sukurini 실행", ja: "ログイン時に Sukurini を起動")
        }
        static var status: String { tr(en: "Login item status", ko: "로그인 항목 상태", ja: "ログイン項目の状態") }
        static var needsApplications: String {
            tr(
                en: "Move Sukurini to /Applications to enable",
                ko: "쓰려면 Sukurini를 /Applications 폴더로 옮겨 주세요",
                ja: "使うには Sukurini を /Applications に移動してください"
            )
        }
        static var openLoginItems: String {
            tr(en: "Open Login Items settings", ko: "로그인 항목 설정 열기", ja: "ログイン項目の設定を開く")
        }

        static var statusNotRegistered: String { tr(en: "Not registered", ko: "등록 안 됨", ja: "未登録") }
        static var statusEnabled: String { tr(en: "Enabled", ko: "켜짐", ja: "オン") }
        static var statusRequiresApproval: String {
            tr(
                en: "Requires approval in System Settings",
                ko: "시스템 설정에서 승인이 필요해요",
                ja: "システム設定での承認が必要です"
            )
        }
        static var statusNotFound: String { tr(en: "Not found", ko: "찾을 수 없음", ja: "見つかりません") }

        static func statusUnknown(_ raw: Int) -> String {
            tr(en: "Unknown (\(raw))", ko: "알 수 없음 (\(raw))", ja: "不明（\(raw)）")
        }
    }
}

extension L10n {
    enum Dock {
        static var header: String { "Dock" }
        static var alwaysShow: String {
            tr(en: "Always show in Dock", ko: "항상 Dock에 표시", ja: "常に Dock に表示")
        }
    }
}

extension L10n {
    enum Shortcut {
        static var header: String { tr(en: "Shortcut", ko: "단축키", ja: "ショートカット") }
        static var toggleGallery: String {
            tr(en: "Show or hide the gallery", ko: "갤러리 열고 닫기", ja: "ギャラリーの表示・非表示")
        }
        static var notSet: String { tr(en: "Not set", ko: "설정 안 됨", ja: "未設定") }
        static var pressKeys: String { tr(en: "Press keys", ko: "키를 눌러 주세요", ja: "キーを押してください") }
        static var recording: String { tr(en: "Press keys…", ko: "키 입력 중…", ja: "キー入力中…") }
        static var record: String { tr(en: "Record Shortcut", ko: "단축키 지정", ja: "ショートカットを設定") }
        static var change: String { tr(en: "Change Shortcut", ko: "단축키 바꾸기", ja: "ショートカットを変更") }

        static var optionalNote: String {
            tr(
                en: "Optional. Sukurini works without a shortcut.",
                ko: "선택이에요. 단축키가 없어도 Sukurini는 잘 동작해요.",
                ja: "任意です。ショートカットがなくても Sukurini は動きます。"
            )
        }
        static var escapeNote: String {
            tr(
                en: "While recording, press Esc to cancel.",
                ko: "입력하는 동안 Esc를 누르면 취소돼요.",
                ja: "入力中に Esc を押すと取り消せます。"
            )
        }
        static var cancelled: String { tr(en: "Recording cancelled.", ko: "취소했어요.", ja: "取り消しました。") }
        static var conflict: String {
            tr(
                en: "Another app may already be using this shortcut.",
                ko: "다른 앱이 이미 쓰고 있는 단축키일 수 있어요.",
                ja: "ほかのアプリがすでに使っているかもしれません。"
            )
        }
        static var needsModifier: String {
            tr(
                en: "Hold at least one of ⌃ ⌥ ⌘ while pressing a key.",
                ko: "⌃ ⌥ ⌘ 가운데 하나는 같이 눌러 주세요.",
                ja: "⌃ ⌥ ⌘ のどれかを一緒に押してください。"
            )
        }
    }
}

extension L10n {
    enum Capture {
        static var header: String { tr(en: "Screenshots", ko: "스크린샷", ja: "スクリーンショット") }
        static var showThumbnail: String {
            tr(
                en: "Show floating thumbnail after capture",
                ko: "찍은 뒤 미리보기 썸네일 표시",
                ja: "撮影後にサムネイルを表示"
            )
        }
        static var thumbnailFooter: String {
            tr(
                en: "macOS holds each screenshot until the preview fades, about 5 seconds. Turning this off saves it right away, so Sukurini reacts immediately.",
                ko: "macOS는 미리보기가 사라질 때까지 5초쯤 스크린샷을 붙잡고 있어요. 이걸 끄면 곧바로 저장돼서 Sukurini도 바로 반응해요.",
                ja: "macOS はプレビューが消えるまで 5 秒ほどスクリーンショットを持ったままにします。オフにするとすぐ保存されるので、Sukurini もすぐ反応します。"
            )
        }
        static var thumbnailFailed: String {
            tr(
                en: "Could not change the macOS thumbnail setting.",
                ko: "macOS 썸네일 설정을 바꾸지 못했어요.",
                ja: "macOS のサムネイル設定を変更できませんでした。"
            )
        }
    }
}

extension L10n {
    enum Updates {
        static var header: String { tr(en: "Updates", ko: "업데이트", ja: "アップデート") }
        static var automatic: String {
            tr(en: "Check for updates automatically", ko: "자동으로 업데이트 확인", ja: "自動でアップデートを確認")
        }
        static var channel: String { tr(en: "Channel", ko: "채널", ja: "チャンネル") }
        static var checkNow: String { tr(en: "Check Now", ko: "지금 확인", ja: "今すぐ確認") }
        static var unavailableTitle: String {
            tr(en: "Updates unavailable", ko: "업데이트를 쓸 수 없어요", ja: "アップデートを利用できません")
        }
        static var neverChecked: String {
            tr(en: "Not checked yet.", ko: "아직 확인한 적 없어요.", ja: "まだ確認していません。")
        }

        static func version(_ value: String) -> String {
            tr(en: "Version \(value)", ko: "버전 \(value)", ja: "バージョン \(value)")
        }

        static func lastChecked(_ value: String) -> String {
            tr(en: "Last checked \(value).", ko: "마지막 확인 \(value).", ja: "最終確認 \(value)。")
        }

        static var stableName: String { tr(en: "Stable", ko: "정식", ja: "安定版") }
        static var previewName: String { tr(en: "Preview", ko: "미리보기", ja: "プレビュー") }

        static var stableSummary: String {
            tr(
                en: "Only fully released versions.",
                ko: "정식으로 나온 버전만 받아요.",
                ja: "正式にリリースされた版だけを受け取ります。"
            )
        }
        static var previewSummary: String {
            tr(
                en: "Also receives pre-releases. Expect rough edges.",
                ko: "미리보기 버전도 받아요. 거친 구석이 있을 수 있어요.",
                ja: "プレリリース版も受け取ります。粗いところがあるかもしれません。"
            )
        }

        static var notBundled: String {
            tr(
                en: "Updates are only available when running the packaged app.",
                ko: "패키지로 만든 앱에서만 업데이트를 쓸 수 있어요.",
                ja: "パッケージ版のアプリでのみアップデートを利用できます。"
            )
        }
        static var feedMissing: String {
            tr(
                en: "This build has no update feed configured.",
                ko: "이 빌드에는 업데이트 피드가 설정돼 있지 않아요.",
                ja: "このビルドにはアップデートフィードが設定されていません。"
            )
        }
        static var keyMissing: String {
            tr(
                en: "This build has no update signing key configured.",
                ko: "이 빌드에는 업데이트 서명 키가 설정돼 있지 않아요.",
                ja: "このビルドにはアップデート用の署名鍵が設定されていません。"
            )
        }

        static func startFailed(_ detail: String) -> String {
            tr(
                en: "The updater could not start: \(detail)",
                ko: "업데이터를 시작하지 못했어요: \(detail)",
                ja: "アップデータを起動できませんでした: \(detail)"
            )
        }
    }
}

extension L10n {
    enum Folders {
        static var header: String { tr(en: "Folders", ko: "폴더", ja: "フォルダ") }
        static var empty: String {
            tr(
                en: "No folders yet. Add the folder where your screenshots are saved.",
                ko: "아직 폴더가 없어요. 스크린샷이 저장되는 폴더를 더해 주세요.",
                ja: "まだフォルダがありません。スクリーンショットが保存されるフォルダを追加してください。"
            )
        }
        static var add: String { tr(en: "Add Folder…", ko: "폴더 추가…", ja: "フォルダを追加…") }
        static var systemBadge: String { tr(en: "System", ko: "시스템", ja: "システム") }
        static var setAsSystem: String { tr(en: "Set as System", ko: "시스템 위치로", ja: "システムの保存先に") }

        static func summary(_ count: Int) -> String {
            tr(
                en: count == 1 ? "1 folder" : "\(count) folders",
                ko: "폴더 \(count)개",
                ja: "\(count) 個のフォルダ"
            )
        }

        static var systemBadgeHelp: String {
            tr(
                en: "macOS saves new screenshots here",
                ko: "macOS가 새 스크린샷을 여기에 저장해요",
                ja: "macOS が新しいスクリーンショットをここに保存します"
            )
        }
        static var setAsSystemHelp: String {
            tr(
                en: "Set as system location for new macOS screenshots",
                ko: "새 macOS 스크린샷이 저장될 위치로 정해요",
                ja: "新しい macOS のスクリーンショットの保存先にします"
            )
        }
        static var removeHelp: String {
            tr(en: "Remove this folder", ko: "이 폴더를 목록에서 빼요", ja: "このフォルダを一覧から外します")
        }
        static var removeBlockedHelp: String {
            tr(
                en: "The system screenshot folder cannot be removed",
                ko: "시스템 스크린샷 폴더는 뺄 수 없어요",
                ja: "システムのスクリーンショットフォルダは外せません"
            )
        }

        static var watchThis: String { tr(en: "Watch This Folder", ko: "이 폴더 지켜보기", ja: "このフォルダを見張る") }
        static var setSystemLocation: String {
            tr(en: "Set as System Location", ko: "시스템 저장 위치로 정하기", ja: "システムの保存先に設定")
        }
        static var removeFolder: String { tr(en: "Remove Folder", ko: "폴더 빼기", ja: "フォルダを外す") }

        static var addPrompt: String { tr(en: "Add", ko: "추가", ja: "追加") }
        static var addMessage: String {
            tr(
                en: "Choose a folder to watch for screenshots.",
                ko: "스크린샷을 지켜볼 폴더를 골라 주세요.",
                ja: "スクリーンショットを見張るフォルダを選んでください。"
            )
        }

        static func removeBlocked(_ name: String) -> String {
            tr(
                en: "\(name) is the system screenshot folder, so it stays in the list.",
                ko: "\(name) 폴더는 시스템 스크린샷 폴더라서 목록에 그대로 남아요.",
                ja: "\(name) はシステムのスクリーンショットフォルダなので、一覧に残ります。"
            )
        }
        static var folderMissingOnDisk: String {
            tr(
                en: "That folder is missing on disk.",
                ko: "그 폴더가 디스크에 없어요.",
                ja: "そのフォルダがディスク上に見つかりません。"
            )
        }
        static func systemLocationApplied(_ name: String) -> String {
            tr(
                en: "New screenshots now save to \(name).",
                ko: "이제 새 스크린샷은 \(name)에 저장돼요.",
                ja: "これから新しいスクリーンショットは \(name) に保存されます。"
            )
        }
        static var systemLocationFailed: String {
            tr(
                en: "Could not update the system screenshot location.",
                ko: "시스템 스크린샷 저장 위치를 바꾸지 못했어요.",
                ja: "システムのスクリーンショットの保存先を変更できませんでした。"
            )
        }
    }
}

extension L10n {
    enum Organize {
        static var header: String { tr(en: "Organize", ko: "정리", ja: "整理") }
        static var enable: String {
            tr(
                en: "Sort new screenshots into date folders",
                ko: "새 스크린샷을 날짜 폴더로 정리",
                ja: "新しいスクリーンショットを日付フォルダに整理"
            )
        }
        static var enableDetail: String {
            tr(
                en: "Each screenshot moves into a subfolder of the watched folder.",
                ko: "지켜보는 폴더 아래 하위 폴더로 옮겨져요.",
                ja: "見張っているフォルダの下のサブフォルダに移動します。"
            )
        }
        static var dateFormat: String { tr(en: "Date format", ko: "날짜 형식", ja: "日付の形式") }
        static var preview: String { tr(en: "Preview", ko: "미리보기", ja: "プレビュー") }
        static var unsaved: String { tr(en: "Unsaved", ko: "저장 안 됨", ja: "未保存") }
        static var sampleName: String { tr(en: "Screenshot", ko: "스크린샷", ja: "スクリーンショット") }
        static var sampleFolder: String { tr(en: "Screenshots", ko: "스크린샷", ja: "スクリーンショット") }

        static var includeSubfolders: String {
            tr(
                en: "Show screenshots in subfolders",
                ko: "하위 폴더에 있는 스크린샷도 보기",
                ja: "サブフォルダのスクリーンショットも表示"
            )
        }
        static var includeSubfoldersRequired: String {
            tr(
                en: "Required while sorting is on, so date folders stay visible.",
                ko: "정리가 켜져 있는 동안엔 필요해요. 날짜 폴더가 계속 보이거든요.",
                ja: "整理がオンの間は必要です。日付フォルダが見えたままになります。"
            )
        }
        static var includeSubfoldersOptional: String {
            tr(
                en: "Keeps already-organized screenshots in the gallery.",
                ko: "이미 정리해 둔 스크린샷도 갤러리에 계속 보여 줘요.",
                ja: "すでに整理済みのスクリーンショットもギャラリーに表示し続けます。"
            )
        }

        static var organizing: String { tr(en: "Organizing", ko: "정리하는 중", ja: "整理中") }
        static var looseScreenshots: String {
            tr(en: "Loose screenshots", ko: "정리 안 된 스크린샷", ja: "未整理のスクリーンショット")
        }

        static func rootCount(_ count: String) -> String {
            tr(en: "\(count) in the folder root", ko: "폴더 맨 위에 \(count)개", ja: "フォルダ直下に \(count) 件")
        }
        static var backfillIdle: String {
            tr(en: "Organize Existing…", ko: "기존 파일 정리…", ja: "既存のファイルを整理…")
        }
        static func backfill(_ count: String) -> String {
            tr(
                en: "Organize \(count) Screenshots…",
                ko: "스크린샷 \(count)개 정리…",
                ja: "スクリーンショット \(count) 件を整理…"
            )
        }
        static func usingPattern(_ pattern: String) -> String {
            tr(en: "Using \(pattern)", ko: "\(pattern) 형식으로 맞췄어요", ja: "\(pattern) の形式に整えました")
        }
        static var datelessHint: String {
            tr(
                en: "Every screenshot goes into the same folder.",
                ko: "모든 스크린샷이 같은 폴더로 들어가요.",
                ja: "すべてのスクリーンショットが同じフォルダに入ります。"
            )
        }

        static func confirmTitle(_ count: String) -> String {
            tr(
                en: "Organize \(count) screenshots into folders?",
                ko: "스크린샷 \(count)개를 폴더로 정리할까요?",
                ja: "スクリーンショット \(count) 件をフォルダに整理しますか？"
            )
        }
        static func confirmBody(_ example: String) -> String {
            tr(
                en: "Files move into subfolders like \(example), inside the watched folder. Nothing is deleted, and you can drag them back at any time. Screenshots already in a subfolder are left alone.",
                ko: "지켜보는 폴더 안에 \(example) 같은 하위 폴더를 만들어 옮겨요. 지우는 건 없고, 언제든 다시 끌어다 놓을 수 있어요. 이미 하위 폴더에 있는 스크린샷은 그대로 둬요.",
                ja: "見張っているフォルダの中に \(example) のようなサブフォルダを作って移動します。削除は行わず、いつでもドラッグで戻せます。すでにサブフォルダにあるスクリーンショットはそのままです。"
            )
        }

        static func moved(_ count: String, duration: String, failed: String?) -> String {
            guard let failed else {
                return tr(
                    en: "Moved \(count) screenshots in \(duration).",
                    ko: "\(duration) 만에 스크린샷 \(count)개를 옮겼어요.",
                    ja: "\(duration)でスクリーンショット \(count) 件を移動しました。"
                )
            }
            return tr(
                en: "Moved \(count) screenshots in \(duration). \(failed) could not be moved.",
                ko: "\(duration) 만에 스크린샷 \(count)개를 옮겼어요. \(failed)개는 옮기지 못했어요.",
                ja: "\(duration)でスクリーンショット \(count) 件を移動しました。\(failed) 件は移動できませんでした。"
            )
        }
        static var moveFailed: String {
            tr(
                en: "No screenshots could be moved.",
                ko: "옮길 수 있는 스크린샷이 하나도 없었어요.",
                ja: "移動できたスクリーンショットはありませんでした。"
            )
        }
        static var nothingToDo: String {
            tr(en: "Nothing to organize.", ko: "정리할 게 없어요.", ja: "整理するものはありません。")
        }
    }
}

extension L10n {
    enum FormatError {
        static var empty: String {
            tr(en: "Enter a date format.", ko: "날짜 형식을 입력해 주세요.", ja: "日付の形式を入力してください。")
        }
        static var absolute: String {
            tr(
                en: "The format cannot start with a slash.",
                ko: "형식은 슬래시로 시작할 수 없어요.",
                ja: "形式をスラッシュで始めることはできません。"
            )
        }
        static var traversal: String {
            tr(
                en: "The format cannot contain . or .. as a folder.",
                ko: "폴더 이름으로 . 이나 .. 는 쓸 수 없어요.",
                ja: "フォルダ名に . や .. は使えません。"
            )
        }
        static var hiddenComponent: String {
            tr(
                en: "A folder starting with a dot would be hidden.",
                ko: "점으로 시작하는 폴더는 숨겨져 버려요.",
                ja: "ドットで始まるフォルダは隠しフォルダになってしまいます。"
            )
        }
        static var illegalCharacter: String {
            tr(
                en: "Colons are not allowed in folder names.",
                ko: "폴더 이름에는 콜론을 쓸 수 없어요.",
                ja: "フォルダ名にコロンは使えません。"
            )
        }
        static var emptyComponent: String {
            tr(
                en: "The format has an empty folder name.",
                ko: "폴더 이름이 비어 있는 곳이 있어요.",
                ja: "フォルダ名が空の箇所があります。"
            )
        }
        static var componentTooLong: String {
            tr(en: "A folder name is too long.", ko: "폴더 이름이 너무 길어요.", ja: "フォルダ名が長すぎます。")
        }
        static func tooDeep(_ maximum: Int) -> String {
            tr(
                en: "Use at most \(maximum) nested folders.",
                ko: "폴더는 \(maximum)단계까지만 겹칠 수 있어요.",
                ja: "フォルダの入れ子は \(maximum) 段までにしてください。"
            )
        }
        static var unbalancedQuote: String {
            tr(
                en: "There is an unclosed quote in the format.",
                ko: "따옴표가 닫히지 않았어요.",
                ja: "閉じていない引用符があります。"
            )
        }
        static var renderFailed: String {
            tr(
                en: "That format does not produce a folder name.",
                ko: "그 형식으로는 폴더 이름이 만들어지지 않아요.",
                ja: "その形式ではフォルダ名が作られません。"
            )
        }
    }
}

extension L10n {
    enum Convert {
        static var header: String { "WebP" }
        static var enable: String {
            tr(
                en: "Convert new screenshots to WebP",
                ko: "새 스크린샷을 WebP 형식으로 변환",
                ja: "新しいスクリーンショットを WebP 形式に変換"
            )
        }
        static var enableDetail: String {
            tr(
                en: "Lossless, and usually about two thirds smaller than PNG.",
                ko: "무손실이라 화질 그대로예요. 보통 PNG보다 3분의 2쯤 작아져요.",
                ja: "可逆圧縮なので画質はそのまま。たいてい PNG より 3 分の 2 ほど小さくなります。"
            )
        }
        static var originalPNG: String { tr(en: "Original PNG", ko: "원본 PNG 이미지", ja: "元の PNG 画像") }
        static var disposalTrash: String { tr(en: "Move to Trash", ko: "휴지통으로 옮기기", ja: "ゴミ箱に入れる") }
        static var disposalDelete: String { tr(en: "Delete", ko: "완전히 지우기", ja: "完全に削除") }
        static var disposalKeep: String { tr(en: "Keep alongside", ko: "그대로 두기", ja: "そのまま残す") }

        static var copyAsPNG: String { tr(en: "Copy as PNG", ko: "PNG로 복사하기", ja: "PNG としてコピー") }
        static var copyAsPNGDetail: String {
            tr(
                en: "Copying or dragging a WebP hands over a temporary PNG instead, for apps that reject WebP.",
                ko: "WebP를 못 받는 앱을 위해, 복사하거나 끌어다 놓을 때 임시 PNG를 대신 건네줘요.",
                ja: "WebP を受け付けないアプリのために、コピーやドラッグのときは一時的な PNG を渡します。"
            )
        }

        static var existingPNGs: String { tr(en: "Existing PNGs", ko: "이미 있는 PNG", ja: "すでにある PNG") }
        static var catchingUp: String { tr(en: "Catching up", ko: "밀린 것 처리 중", ja: "たまった分を処理中") }
        static var converting: String { tr(en: "Converting", ko: "변환하는 중", ja: "変換中") }
        static var reclaimed: String { tr(en: "Reclaimed", ko: "되찾은 공간", ja: "空いた容量") }

        static func progress(_ done: String, total: String) -> String {
            tr(en: "\(done) of \(total)", ko: "\(total)개 중 \(done)개", ja: "\(total) 件中 \(done) 件")
        }
        static func remaining(_ duration: String) -> String {
            tr(en: "~\(duration) left", ko: "\(duration)쯤 남음", ja: "残り \(duration)ほど")
        }
        static func estimate(_ count: String, saved: String) -> String {
            tr(
                en: "\(count) files · about \(saved) to reclaim",
                ko: "파일 \(count)개 · \(saved)쯤 되찾을 수 있어요",
                ja: "\(count) 件 · \(saved)ほど空けられます"
            )
        }
        static func reclaimedSoFar(_ saved: String, percent: Int) -> String {
            tr(
                en: "\(saved) so far · \(percent)% smaller",
                ko: "지금까지 \(saved) · \(percent)% 작아짐",
                ja: "これまで \(saved) · \(percent)% 小さく"
            )
        }

        static var backfillIdle: String {
            tr(en: "Backfill Existing PNGs…", ko: "이미 있는 PNG 변환…", ja: "すでにある PNG を変換…")
        }
        static func backfill(_ count: Int) -> String {
            tr(en: "Backfill \(count) PNGs…", ko: "PNG \(count)개 변환…", ja: "PNG \(count) 件を変換…")
        }

        static var footerDefault: String {
            tr(
                en: "Applies to screenshots taken from now on. Use Backfill for the ones you already have.",
                ko: "지금부터 찍는 스크린샷에 적용돼요. 이미 있는 파일은 위 버튼으로 한 번에 바꿀 수 있어요.",
                ja: "これから撮るスクリーンショットに適用されます。すでにある分は上のボタンでまとめて変換できます。"
            )
        }
        static func footerSince(_ stamp: String) -> String {
            tr(
                en: "Screenshots added since \(stamp) convert automatically, even ones that arrived while Sukurini was closed.",
                ko: "\(stamp) 이후에 생긴 스크린샷은 저절로 변환돼요. Sukurini가 꺼져 있는 동안 들어온 것도요.",
                ja: "\(stamp) 以降に増えたスクリーンショットは自動で変換されます。Sukurini が閉じている間に届いた分もです。"
            )
        }

        static func confirmTitle(_ count: String) -> String {
            tr(
                en: "Convert \(count) screenshots to WebP?",
                ko: "스크린샷 \(count)개를 WebP로 바꿀까요?",
                ja: "スクリーンショット \(count) 件を WebP に変換しますか？"
            )
        }
        static func confirmBody(saved: String, disposal: WebPDisposal) -> String {
            let fate: String
            switch disposal {
            case .trash:
                fate = tr(
                    en: "The original PNGs move to the Trash, so you can restore them.",
                    ko: "원본 PNG는 휴지통으로 가니까 언제든 되돌릴 수 있어요.",
                    ja: "元の PNG はゴミ箱に入るので、いつでも戻せます。"
                )
            case .delete:
                fate = tr(
                    en: "The original PNGs are deleted permanently and cannot be recovered.",
                    ko: "원본 PNG는 완전히 지워져서 되살릴 수 없어요.",
                    ja: "元の PNG は完全に削除され、元に戻せません。"
                )
            case .keep:
                fate = tr(
                    en: "The original PNGs are kept, so this will use more disk space rather than less.",
                    ko: "원본 PNG를 그대로 두니까 오히려 디스크를 더 쓰게 돼요.",
                    ja: "元の PNG を残すので、かえってディスクを多く使うことになります。"
                )
            }
            return tr(
                en: "This runs in the background and reclaims roughly \(saved). \(fate) Each file is verified pixel by pixel first, and anything that fails verification is left as PNG.",
                ko: "뒤에서 조용히 돌아가고 \(saved)쯤 되찾아요. \(fate) 파일마다 픽셀 단위로 먼저 확인하고, 확인에 실패한 건 PNG 그대로 둬요.",
                ja: "バックグラウンドで動き、\(saved)ほど空きます。\(fate) ファイルごとにピクセル単位で先に確認し、確認できなかったものは PNG のまま残します。"
            )
        }

        static func completed(count: String, duration: String, saved: String, percent: Int, catchUp: Bool) -> String {
            guard catchUp else {
                return tr(
                    en: "Converted \(count) screenshots in \(duration) and reclaimed \(saved) — \(percent)% smaller.",
                    ko: "\(duration) 만에 스크린샷 \(count)개를 바꾸고 \(saved)를 되찾았어요 — \(percent)% 작아졌어요.",
                    ja: "\(duration)でスクリーンショット \(count) 件を変換し、\(saved)を取り戻しました — \(percent)% 小さくなりました。"
                )
            }
            return tr(
                en: "Caught up on \(count) screenshots in \(duration) and reclaimed \(saved) — \(percent)% smaller.",
                ko: "\(duration) 만에 밀린 스크린샷 \(count)개를 처리하고 \(saved)를 되찾았어요 — \(percent)% 작아졌어요.",
                ja: "\(duration)でたまっていたスクリーンショット \(count) 件を処理し、\(saved)を取り戻しました — \(percent)% 小さくなりました。"
            )
        }

        static var nothingConverted: String {
            tr(
                en: "No files were converted.",
                ko: "바뀐 파일이 하나도 없어요.",
                ja: "変換されたファイルはありません。"
            )
        }
    }
}

extension L10n {
    enum Search {
        static var header: String { tr(en: "Search", ko: "검색", ja: "検索") }
        static var ocrEnable: String {
            tr(
                en: "Search text inside screenshots",
                ko: "스크린샷 속 글자까지 검색",
                ja: "スクリーンショットの中の文字も検索"
            )
        }
        static var indexing: String { tr(en: "Indexing", ko: "색인", ja: "インデックス") }
        static var notRunning: String { tr(en: "Not running", ko: "돌지 않는 중", ja: "動いていません") }

        static func indexed(done: Int, total: Int) -> String {
            tr(
                en: "Indexed \(done) / \(total)",
                ko: "\(total)개 중 \(done)개 색인",
                ja: "\(total) 件中 \(done) 件をインデックス"
            )
        }

        static var lazyOnBattery: String {
            tr(
                en: "Lazy indexing on battery",
                ko: "배터리로 쓸 땐 천천히 색인",
                ja: "バッテリー使用中はゆっくりインデックス"
            )
        }
        static var lazyOnBatteryDetail: String {
            tr(
                en: "Indexes more slowly while running on battery.",
                ko: "배터리로 돌아갈 땐 색인 속도를 늦춰요.",
                ja: "バッテリーで動いている間はインデックスの速度を落とします。"
            )
        }
        static var pauseLowPower: String {
            tr(
                en: "Pause indexing in Low Power Mode",
                ko: "저전력 모드에선 색인 멈추기",
                ja: "低電力モードではインデックスを一時停止"
            )
        }
        static var pauseLowPowerDetail: String {
            tr(
                en: "Holds indexing until Low Power Mode is off.",
                ko: "저전력 모드가 꺼질 때까지 색인을 멈춰 둬요.",
                ja: "低電力モードが解除されるまでインデックスを止めておきます。"
            )
        }
    }
}

extension L10n {
    enum Semantic {
        static var title: String { tr(en: "AI image search", ko: "AI 이미지 검색", ja: "AI 画像検索") }
        static var detail: String {
            tr(
                en: "Finds screenshots by what they look like, not just their text.",
                ko: "글자뿐 아니라 그림 그 자체로도 스크린샷을 찾아 줘요.",
                ja: "文字だけでなく、見た目そのものからもスクリーンショットを探します。"
            )
        }
        static var footer: String {
            tr(
                en: "Downloads a model once, then runs entirely on this Mac. Text search keeps working whether this is on or off.",
                ko: "모델을 한 번만 내려받고 그다음엔 전부 이 Mac 안에서만 돌아가요. 켜든 끄든 글자 검색은 그대로예요.",
                ja: "モデルを一度だけダウンロードし、あとはすべてこの Mac の中だけで動きます。オンでもオフでもテキスト検索はそのままです。"
            )
        }

        static var model: String { tr(en: "Model", ko: "모델", ja: "モデル") }
        static var status: String { tr(en: "Status", ko: "상태", ja: "状態") }
        static var onDisk: String { tr(en: "On disk", ko: "디스크 사용량", ja: "ディスク使用量") }

        static var startOver: String { tr(en: "Start Over", ko: "처음부터 다시", ja: "最初からやり直す") }
        static var resume: String { tr(en: "Resume", ko: "이어받기", ja: "再開") }
        static var download: String { tr(en: "Download", ko: "내려받기", ja: "ダウンロード") }
        static var resumeDownload: String { tr(en: "Resume Download", ko: "이어서 내려받기", ja: "ダウンロードを再開") }
        static var downloadAgain: String { tr(en: "Download Again", ko: "다시 내려받기", ja: "もう一度ダウンロード") }
        static var removeModel: String { tr(en: "Remove Model…", ko: "모델 지우기…", ja: "モデルを削除…") }

        static var filesMissing: String {
            tr(
                en: "Model files are missing or damaged.",
                ko: "모델 파일이 없거나 망가졌어요.",
                ja: "モデルファイルが見つからないか壊れています。"
            )
        }
        static func filesMissingDetail(_ count: Int) -> String {
            tr(
                en: "\(count) file\(count == 1 ? "" : "s") could not be verified. AI search stays off until the model is downloaded again. Your existing text search is unaffected.",
                ko: "파일 \(count)개를 확인하지 못했어요. 모델을 다시 받을 때까지 AI 검색은 꺼진 채로 있어요. 쓰던 글자 검색은 그대로예요.",
                ja: "\(count) 個のファイルを確認できませんでした。モデルを再ダウンロードするまで AI 検索はオフのままです。これまでのテキスト検索には影響しません。"
            )
        }
        static var downloadFailed: String {
            tr(en: "Download failed.", ko: "내려받기에 실패했어요.", ja: "ダウンロードに失敗しました。")
        }

        static var stateNotDownloaded: String {
            tr(en: "Not downloaded", ko: "안 받음", ja: "未ダウンロード")
        }
        static func stateDownloading(done: String, total: String) -> String {
            tr(
                en: "Downloading \(done) of \(total)",
                ko: "\(total) 중 \(done) 받는 중",
                ja: "\(total) 中 \(done) をダウンロード中"
            )
        }
        static var stateMissing: String { tr(en: "Model missing", ko: "모델 없음", ja: "モデルがありません") }
        static var stateFailed: String { tr(en: "Failed", ko: "실패", ja: "失敗") }
        static func stateReady(_ count: Int) -> String {
            tr(en: "\(count) indexed", ko: "\(count)개 색인됨", ja: "\(count) 件をインデックス済み")
        }

        static func downloadPrompt(name: String, size: String) -> String {
            tr(
                en: "\(name) — \(size) download.",
                ko: "\(name) — \(size) 내려받아요.",
                ja: "\(name) — \(size) をダウンロードします。"
            )
        }
        static func resumePrompt(done: String, remaining: String) -> String {
            tr(
                en: "\(done) already downloaded, \(remaining) to go.",
                ko: "\(done)는 이미 받았고, \(remaining) 남았어요.",
                ja: "\(done) はダウンロード済みで、残り \(remaining) です。"
            )
        }

        static func diskUsage(model: String, index: String, total: String) -> String {
            tr(
                en: "\(total)  (model \(model), index \(index))",
                ko: "\(total)  (모델 \(model), 색인 \(index))",
                ja: "\(total)（モデル \(model)、インデックス \(index)）"
            )
        }

        static func removeTitle(_ name: String) -> String {
            tr(en: "Remove \(name)?", ko: "\(name) 모델을 지울까요?", ja: "\(name) を削除しますか？")
        }
        static var removeFallback: String {
            tr(
                en: "This deletes the downloaded model.",
                ko: "내려받은 모델을 지워요.",
                ja: "ダウンロード済みのモデルを削除します。"
            )
        }
        static func removeWarning(total: String, indexed: Int) -> String {
            guard indexed > 0 else {
                return tr(
                    en: "This frees \(total) by deleting the downloaded model. Turning AI image search back on downloads it again. Your screenshots and text search are not affected.",
                    ko: "내려받은 모델을 지워서 \(total)를 비워요. AI 이미지 검색을 다시 켜면 또 받아요. 스크린샷과 글자 검색은 그대로예요.",
                    ja: "ダウンロード済みのモデルを削除して \(total) を空けます。AI 画像検索をもう一度オンにすると再びダウンロードします。スクリーンショットとテキスト検索には影響しません。"
                )
            }
            return tr(
                en: "This frees \(total) by deleting the model and the search index for \(indexed) screenshot\(indexed == 1 ? "" : "s"). Turning AI image search back on downloads the model again and re-indexes everything. Your screenshots and text search are not affected.",
                ko: "모델과 스크린샷 \(indexed)개의 검색 색인을 지워서 \(total)를 비워요. AI 이미지 검색을 다시 켜면 모델을 또 받고 처음부터 색인해요. 스크린샷과 글자 검색은 그대로예요.",
                ja: "モデルとスクリーンショット \(indexed) 件分の検索インデックスを削除して \(total) を空けます。AI 画像検索をもう一度オンにすると、モデルを再ダウンロードして一から作り直します。スクリーンショットとテキスト検索には影響しません。"
            )
        }
    }
}

extension L10n {
    enum Gallery {
        static var searchPlaceholder: String {
            tr(en: "Searching in Screenshots", ko: "스크린샷에서 검색", ja: "スクリーンショットを検索")
        }
        static var clear: String { tr(en: "Clear", ko: "지우기", ja: "消去") }
        static var search: String { tr(en: "Search", ko: "검색", ja: "検索") }
        static var settings: String { tr(en: "Settings", ko: "설정", ja: "設定") }
        static var settingsTooltip: String { tr(en: "Sukurini settings", ko: "Sukurini 설정", ja: "Sukurini の設定") }
        static var scrollToTop: String { tr(en: "Scroll to top", ko: "맨 위로", ja: "いちばん上へ") }
        static var bestMatches: String { tr(en: "Best matches", ko: "가장 잘 맞는 결과", ja: "いちばん近い結果") }

        static var emptyFolder: String {
            tr(
                en: "No screenshots in this folder",
                ko: "이 폴더엔 스크린샷이 없어요",
                ja: "このフォルダにスクリーンショットはありません"
            )
        }
        static var emptySearch: String {
            tr(
                en: "No matching screenshots",
                ko: "맞는 스크린샷이 없어요",
                ja: "一致するスクリーンショットはありません"
            )
        }

        static var open: String { tr(en: "Open", ko: "열기", ja: "開く") }
        static func openMany(_ count: Int) -> String {
            tr(en: "Open \(count) Screenshots", ko: "스크린샷 \(count)개 열기", ja: "スクリーンショット \(count) 件を開く")
        }
        static var quickLook: String { tr(en: "Quick Look", ko: "훑어보기", ja: "クイックルック") }
        static func quickLookMany(_ count: Int) -> String {
            tr(
                en: "Quick Look \(count) Screenshots",
                ko: "스크린샷 \(count)개 훑어보기",
                ja: "スクリーンショット \(count) 件をクイックルック"
            )
        }
        static var reveal: String { tr(en: "Reveal in Finder", ko: "파인더에서 보기", ja: "ファインダに表示") }
        static var copy: String { tr(en: "Copy", ko: "복사하기", ja: "コピー") }
        static var copyAsPNG: String { tr(en: "Copy as PNG", ko: "PNG로 복사하기", ja: "PNG としてコピー") }
        static func copyMany(_ count: Int) -> String {
            tr(en: "Copy \(count) Files", ko: "파일 \(count)개 복사하기", ja: "\(count) 件のファイルをコピー")
        }
        static func copyManyAsPNG(_ count: Int) -> String {
            tr(
                en: "Copy \(count) Files as PNG",
                ko: "파일 \(count)개를 PNG로 복사하기",
                ja: "\(count) 件のファイルを PNG としてコピー"
            )
        }
        static var trash: String { tr(en: "Move to Trash", ko: "휴지통으로 옮기기", ja: "ゴミ箱に入れる") }
        static func trashMany(_ count: Int) -> String {
            tr(
                en: "Move \(count) to Trash",
                ko: "\(count)개를 휴지통으로 옮기기",
                ja: "\(count) 件をゴミ箱に入れる"
            )
        }

        static var sortRelevance: String { tr(en: "Relevance", ko: "관련도순", ja: "関連度順") }
        static var sortDate: String { tr(en: "Newest first", ko: "최신순", ja: "新しい順") }
        static var sortRelevanceSummary: String {
            tr(en: "Closest matches first.", ko: "가장 잘 맞는 것부터 보여 줘요.", ja: "いちばん近いものから表示します。")
        }
        static var sortDateSummary: String {
            tr(en: "Most recent screenshots first.", ko: "최근에 찍은 것부터 보여 줘요.", ja: "最近撮ったものから表示します。")
        }
    }
}

extension L10n {
    enum Onboarding {
        static var permissionTitleBlocked: String {
            tr(
                en: "Let Sukurini manage your screenshots",
                ko: "Sukurini가 스크린샷을 관리할 수 있게 해 주세요",
                ja: "Sukurini がスクリーンショットを管理できるようにしてください"
            )
        }
        static var permissionTitleReady: String {
            tr(
                en: "Sukurini can manage your screenshots",
                ko: "Sukurini가 스크린샷을 관리할 수 있어요",
                ja: "Sukurini はスクリーンショットを管理できます"
            )
        }
        static var permissionSubtitle: String {
            tr(
                en: "macOS keeps folders like Desktop and Documents private until you allow an app in. Sukurini only touches the folder your screenshots land in.",
                ko: "macOS는 데스크탑이나 서류 같은 폴더를 허락하기 전까진 앱에 안 보여 줘요. Sukurini는 스크린샷이 떨어지는 폴더 하나만 다뤄요.",
                ja: "macOS はデスクトップや書類などのフォルダを、許可するまでアプリに見せません。Sukurini はスクリーンショットが保存されるフォルダだけを扱います。"
            )
        }
        static var checkingAccess: String {
            tr(en: "Checking folder access…", ko: "폴더 접근을 확인하는 중…", ja: "フォルダへのアクセスを確認中…")
        }
        static var probeReadable: String { tr(en: "Readable", ko: "읽을 수 있음", ja: "読み取れます") }
        static var probeDenied: String { tr(en: "Not allowed", ko: "허락 안 됨", ja: "許可されていません") }
        static var probeMissing: String { tr(en: "Missing", ko: "없음", ja: "見つかりません") }

        static var nameJoiner: String { tr(en: " and ", ko: ", ", ja: "と") }

        static var accessMissingMessage: String {
            tr(
                en: "That folder is not on disk right now. Sukurini picks it up again if it comes back, or you can choose another folder in Settings.",
                ko: "그 폴더가 지금 디스크에 없어요. 다시 생기면 Sukurini가 알아서 잡아요. 설정에서 다른 폴더를 골라도 돼요.",
                ja: "そのフォルダは今ディスク上にありません。戻ってくれば Sukurini が自動で拾います。設定で別のフォルダを選ぶこともできます。"
            )
        }
        static func accessDeniedMessage(_ names: String) -> String {
            tr(
                en: "Allow Sukurini if macOS asks for \(names). If no dialog appears, macOS already has an answer on file — open Privacy & Security › Files and Folders, switch Sukurini on, then check again.",
                ko: "macOS가 \(names) 접근을 물어보면 허락해 주세요. 아무 창도 안 뜨면 macOS가 이미 답을 기억하고 있는 거예요 — 개인정보 보호 및 보안 › 파일 및 폴더에서 Sukurini를 켜고 다시 확인해 주세요.",
                ja: "macOS が \(names) へのアクセスを尋ねたら許可してください。何も表示されないときは、macOS がすでに答えを覚えています — プライバシーとセキュリティ › ファイルとフォルダで Sukurini をオンにして、もう一度確認してください。"
            )
        }
        static var openPrivacySettings: String {
            tr(en: "Open Privacy Settings", ko: "개인정보 설정 열기", ja: "プライバシー設定を開く")
        }
        static var checkAgain: String { tr(en: "Check Again", ko: "다시 확인", ja: "もう一度確認") }
        static var skipForNow: String { tr(en: "Skip for now", ko: "나중에 하기", ja: "あとにする") }

        static var recommendationsTitle: String {
            tr(en: "Recommended setup", ko: "이렇게 맞춰 두면 좋아요", ja: "おすすめの設定")
        }
        static var recommendationsSubtitle: String {
            tr(
                en: "Three settings that make Sukurini feel right from the first screenshot. Untick anything you would rather keep as it is.",
                ko: "첫 스크린샷부터 Sukurini가 제 몫을 하게 해 주는 세 가지예요. 그대로 두고 싶은 건 체크를 풀면 돼요.",
                ja: "最初のスクリーンショットから Sukurini がしっくりくる 3 つの設定です。そのままにしたいものはチェックを外してください。"
            )
        }
        static var alreadySet: String { tr(en: "Already set", ko: "이미 됨", ja: "設定済み") }

        static var recommendThumbnail: String {
            tr(
                en: "Turn off the floating thumbnail",
                ko: "떠 있는 미리보기 썸네일 끄기",
                ja: "浮かぶサムネイルをオフにする"
            )
        }
        static var recommendThumbnailDetail: String {
            tr(
                en: "macOS holds each screenshot for about five seconds while the preview fades. Off, it lands right away.",
                ko: "macOS는 미리보기가 사라지는 5초 남짓 동안 스크린샷을 붙잡고 있어요. 꺼 두면 바로 떨어져요.",
                ja: "macOS はプレビューが消えるまでの 5 秒ほど、スクリーンショットを持ったままにします。オフにすればすぐ保存されます。"
            )
        }
        static func recommendFolder(_ path: String) -> String {
            tr(
                en: "Keep screenshots in \(path)",
                ko: "스크린샷을 \(path)에 모으기",
                ja: "スクリーンショットを \(path) にまとめる"
            )
        }
        static var recommendFolderDetail: String {
            tr(
                en: "Creates the folder, tells macOS to save there, and watches it here.",
                ko: "폴더를 만들고, macOS가 거기 저장하게 하고, Sukurini가 그 폴더를 지켜봐요.",
                ja: "フォルダを作り、macOS がそこに保存するようにして、Sukurini がそのフォルダを見張ります。"
            )
        }
        static func recommendFolderMoveDetail(_ current: String) -> String {
            tr(
                en: "Creates the folder, tells macOS to save there instead of \(current), and watches it here.",
                ko: "폴더를 만들고, macOS가 \(current) 대신 거기 저장하게 한 다음 Sukurini가 지켜봐요.",
                ja: "フォルダを作り、macOS が \(current) の代わりにそこへ保存するようにして、Sukurini が見張ります。"
            )
        }
        static func moveExistingTitle(_ count: String) -> String {
            tr(
                en: "Move the \(count) screenshots already there",
                ko: "이미 있는 스크린샷 \(count)개도 함께 옮기기",
                ja: "すでにある \(count) 件のスクリーンショットも一緒に移す"
            )
        }
        static func moveExistingDetail(source: String, size: String) -> String {
            tr(
                en: "From \(source), \(size). Names stay the same, nothing is deleted, and you can drag them back any time.",
                ko: "\(source)에서 \(size)만큼요. 이름은 그대로고 지우는 건 없어요. 언제든 다시 끌어다 놓으면 돼요.",
                ja: "\(source) から \(size) 分です。名前はそのまま、削除もしません。いつでも戻せます。"
            )
        }
        static var moveExistingSurveying: String {
            tr(en: "Looking for screenshots to move…", ko: "옮길 스크린샷을 찾는 중…", ja: "移すスクリーンショットを探しています…")
        }
        static var moveRunning: String {
            tr(en: "Moving screenshots…", ko: "스크린샷을 옮기는 중…", ja: "スクリーンショットを移しています…")
        }
        static func confirmMoveTitle(count: String, source: String) -> String {
            tr(
                en: "Move \(count) screenshots out of \(source)?",
                ko: "\(source)에 있는 스크린샷 \(count)개를 옮길까요?",
                ja: "\(source) にあるスクリーンショット \(count) 件を移しますか？"
            )
        }
        static func confirmMoveBody(destination: String) -> String {
            tr(
                en: "They move into \(destination), keeping their names. Only files that look like screenshots are moved — everything else stays put. Nothing is deleted, so you can move them back in Finder.",
                ko: "이름 그대로 \(destination)로 옮겨요. 스크린샷처럼 보이는 파일만 옮기고 나머지는 그 자리에 둬요. 지우는 게 아니라서 Finder에서 되돌릴 수 있어요.",
                ja: "名前はそのままで \(destination) に移します。スクリーンショットらしいファイルだけを移し、それ以外はそのまま残します。削除ではないので Finder で戻せます。"
            )
        }
        static var moveAction: String { tr(en: "Move", ko: "옮기기", ja: "移す") }
        static var keepInPlaceAction: String { tr(en: "Leave Them", ko: "그대로 두기", ja: "そのままにする") }

        static func summaryMoved(count: String, source: String) -> String {
            tr(
                en: "Moved \(count) screenshots out of \(source), so your history came along.",
                ko: "\(source)에 있던 스크린샷 \(count)개를 옮겨서, 지금까지 모은 것도 그대로 따라왔어요.",
                ja: "\(source) にあった \(count) 件のスクリーンショットを移したので、これまでの分もそのまま残っています。"
            )
        }
        static func failureMove(_ count: String) -> String {
            tr(
                en: "\(count) screenshots could not be moved and stayed where they were.",
                ko: "스크린샷 \(count)개는 옮기지 못해서 원래 자리에 남아 있어요.",
                ja: "\(count) 件のスクリーンショットは移せず、元の場所に残りました。"
            )
        }
        static func failureAdopt(_ path: String) -> String {
            tr(
                en: "Could not point macOS at \(path). You can set it in Settings › Folders.",
                ko: "macOS가 \(path)에 저장하도록 바꾸지 못했어요. 설정 › 폴더에서 지정할 수 있어요.",
                ja: "macOS の保存先を \(path) に変更できませんでした。設定 › フォルダで指定できます。"
            )
        }

        static func recommendWebPDetail(_ disposal: WebPDisposal) -> String {
            let fate: String
            switch disposal {
            case .trash:
                fate = tr(en: "The original PNG moves to the Trash", ko: "원본 PNG는 휴지통으로 가요", ja: "元の PNG はゴミ箱に入ります")
            case .delete:
                fate = tr(en: "The original PNG is deleted", ko: "원본 PNG는 지워져요", ja: "元の PNG は削除されます")
            case .keep:
                fate = tr(en: "The original PNG is kept alongside", ko: "원본 PNG는 옆에 그대로 남아요", ja: "元の PNG は横に残ります")
            }
            return tr(
                en: "Lossless, and usually about two thirds smaller than PNG. \(fate) once the copy is verified pixel by pixel.",
                ko: "무손실이라 화질 그대로고, 보통 PNG보다 3분의 2쯤 작아져요. 픽셀 단위로 확인이 끝나면 \(fate).",
                ja: "可逆圧縮なので画質はそのまま、たいてい PNG より 3 分の 2 ほど小さくなります。ピクセル単位の確認が終わると\(fate)。"
            )
        }

        static var backfillDone: String {
            tr(en: "Done — that space is back", ko: "끝났어요 — 공간을 되찾았어요", ja: "完了 — 空き容量が戻ってきました")
        }
        static var backfillRunning: String {
            tr(en: "Reclaiming space…", ko: "공간을 되찾는 중…", ja: "空き容量を取り戻しています…")
        }
        static var backfillNothing: String {
            tr(en: "Nothing left to convert", ko: "더 바꿀 게 없어요", ja: "変換するものはもうありません")
        }
        static var backfillReady: String {
            tr(
                en: "Reclaim space on the screenshots you already have",
                ko: "이미 있는 스크린샷에서 공간을 되찾아요",
                ja: "すでにあるスクリーンショットから空き容量を取り戻す"
            )
        }

        static var fallbackFolderName: String {
            tr(en: "your screenshot folder", ko: "스크린샷 폴더", ja: "スクリーンショットのフォルダ")
        }
        static var backfillDoneSubtitle: String {
            tr(
                en: "Sukurini keeps doing this for every new screenshot from now on.",
                ko: "이제부터 새 스크린샷마다 Sukurini가 알아서 계속해 줘요.",
                ja: "これからは新しいスクリーンショットごとに Sukurini が自動で続けます。"
            )
        }
        static var backfillRunningSubtitle: String {
            tr(
                en: "This runs in the background. You can stop it at any time.",
                ko: "뒤에서 조용히 돌아가요. 언제든 멈출 수 있어요.",
                ja: "バックグラウンドで動きます。いつでも止められます。"
            )
        }
        static func backfillNothingSubtitle(_ folder: String) -> String {
            tr(
                en: "Every screenshot in \(folder) is already WebP.",
                ko: "\(folder) 안 스크린샷은 이미 전부 WebP예요.",
                ja: "\(folder) の中のスクリーンショットはすでにすべて WebP です。"
            )
        }
        static func backfillReadySubtitle(_ folder: String) -> String {
            tr(
                en: "Sukurini can convert the PNGs already sitting in \(folder). It runs in the background and you can stop it at any time.",
                ko: "\(folder)에 이미 있는 PNG를 Sukurini가 바꿔 줄 수 있어요. 뒤에서 돌아가고 언제든 멈출 수 있어요.",
                ja: "\(folder) にすでにある PNG を Sukurini が変換できます。バックグラウンドで動き、いつでも止められます。"
            )
        }

        static var statConverted: String { tr(en: "converted", ko: "변환됨", ja: "変換") }
        static var statSmaller: String { tr(en: "smaller", ko: "작아짐", ja: "縮小") }
        static var statRemaining: String { tr(en: "remaining", ko: "남음", ja: "残り") }
        static var statElapsed: String { tr(en: "elapsed", ko: "걸린 시간", ja: "経過") }

        static var heroNothingConverted: String {
            tr(en: "Nothing was converted.", ko: "바뀐 게 없어요.", ja: "変換されたものはありません。")
        }
        static func heroReclaimed(_ count: String) -> String {
            tr(
                en: "reclaimed from \(count) screenshots",
                ko: "스크린샷 \(count)개에서 되찾았어요",
                ja: "スクリーンショット \(count) 件から取り戻しました"
            )
        }
        static func heroRunning(done: String, total: String) -> String {
            tr(
                en: "reclaimed so far · \(done) of \(total) checked",
                ko: "지금까지 되찾은 양 · \(total)개 중 \(done)개 확인",
                ja: "これまでの取り戻し量 · \(total) 件中 \(done) 件を確認"
            )
        }
        static var heroStarting: String { tr(en: "starting…", ko: "시작하는 중…", ja: "開始しています…") }
        static var heroCounting: String {
            tr(en: "counting your screenshots…", ko: "스크린샷을 세는 중…", ja: "スクリーンショットを数えています…")
        }
        static var heroNothingToConvert: String {
            tr(en: "Nothing to convert here.", ko: "여기엔 바꿀 게 없어요.", ja: "ここには変換するものがありません。")
        }
        static func heroEstimate(count: String, total: String) -> String {
            tr(
                en: "estimated saving across \(count) PNGs, \(total) today",
                ko: "PNG \(count)개 기준 예상 절감량, 지금은 \(total)",
                ja: "PNG \(count) 件でのおおよその節約量、現在は \(total)"
            )
        }

        static func disposalNotice(_ disposal: WebPDisposal) -> String {
            switch disposal {
            case .trash:
                return tr(
                    en: "Every file is decoded and compared pixel by pixel first. The original PNG then moves to the Trash, so you can put it back.",
                    ko: "파일마다 먼저 풀어서 픽셀 단위로 맞춰 봐요. 그다음 원본 PNG는 휴지통으로 가니까 되돌릴 수 있어요.",
                    ja: "ファイルごとにまず展開してピクセル単位で比べます。そのあと元の PNG はゴミ箱に入るので、戻すことができます。"
                )
            case .delete:
                return tr(
                    en: "Every file is decoded and compared pixel by pixel first. The original PNG is then deleted permanently and cannot be recovered.",
                    ko: "파일마다 먼저 풀어서 픽셀 단위로 맞춰 봐요. 그다음 원본 PNG는 완전히 지워져서 되살릴 수 없어요.",
                    ja: "ファイルごとにまず展開してピクセル単位で比べます。そのあと元の PNG は完全に削除され、元に戻せません。"
                )
            case .keep:
                return tr(
                    en: "Every file is decoded and compared pixel by pixel first. The original PNG is kept, so this uses more disk space rather than less.",
                    ko: "파일마다 먼저 풀어서 픽셀 단위로 맞춰 봐요. 원본 PNG는 그대로 두니까 디스크를 오히려 더 쓰게 돼요.",
                    ja: "ファイルごとにまず展開してピクセル単位で比べます。元の PNG は残すので、かえってディスクを多く使います。"
                )
            }
        }

        static var welcomeTitle: String {
            tr(en: "Welcome to Sukurini!", ko: "Sukurini에 오신 걸 환영해요!", ja: "Sukurini へようこそ！")
        }
        static var welcomeSubtitle: String {
            tr(
                en: "It lives in the menu bar. Click the icon for the gallery, or press the icon and drag to drop your newest screenshot anywhere.",
                ko: "메뉴 막대에 살고 있어요. 아이콘을 누르면 갤러리가 열리고, 아이콘을 누른 채 끌면 가장 최근 스크린샷을 아무 데나 떨어뜨릴 수 있어요.",
                ja: "メニューバーに常駐します。アイコンをクリックするとギャラリーが開き、アイコンを押したままドラッグすれば最新のスクリーンショットをどこにでも置けます。"
            )
        }

        static func summaryFolderStaged(_ path: String) -> String {
            tr(
                en: "New screenshots save to \(path), and Sukurini watches it.",
                ko: "새 스크린샷은 \(path)에 저장되고, Sukurini가 그 폴더를 지켜봐요.",
                ja: "新しいスクリーンショットは \(path) に保存され、Sukurini がそのフォルダを見張ります。"
            )
        }
        static func summaryFolderWatching(_ name: String) -> String {
            tr(
                en: "Sukurini watches \(name).",
                ko: "Sukurini가 \(name) 폴더를 지켜봐요.",
                ja: "Sukurini が \(name) を見張ります。"
            )
        }
        static var summaryThumbnailOff: String {
            tr(
                en: "The floating thumbnail is off, so screenshots land right away.",
                ko: "떠 있는 썸네일을 껐으니 스크린샷이 바로 떨어져요.",
                ja: "浮かぶサムネイルをオフにしたので、スクリーンショットがすぐ保存されます。"
            )
        }
        static var summaryWebP: String {
            tr(
                en: "New screenshots convert to WebP automatically.",
                ko: "새 스크린샷은 알아서 WebP로 바뀌어요.",
                ja: "新しいスクリーンショットは自動で WebP に変換されます。"
            )
        }
        static func summaryReclaimed(saved: String, count: String) -> String {
            tr(
                en: "Reclaimed \(saved) from \(count) screenshots.",
                ko: "스크린샷 \(count)개에서 \(saved)를 되찾았어요.",
                ja: "スクリーンショット \(count) 件から \(saved) を取り戻しました。"
            )
        }
        static var summaryOCR: String {
            tr(
                en: "Text inside screenshots is indexed, so search finds words in images.",
                ko: "스크린샷 속 글자까지 색인해서, 이미지 안 단어도 검색돼요.",
                ja: "スクリーンショットの中の文字までインデックスするので、画像の中の言葉も検索できます。"
            )
        }

        static var failureThumbnail: String {
            tr(
                en: "Could not turn off the macOS thumbnail preview.",
                ko: "macOS 썸네일 미리보기를 끄지 못했어요.",
                ja: "macOS のサムネイルプレビューをオフにできませんでした。"
            )
        }
        static func failureFolder(_ path: String) -> String {
            tr(
                en: "Could not create \(path).",
                ko: "\(path) 폴더를 만들지 못했어요.",
                ja: "\(path) を作成できませんでした。"
            )
        }

        static var starTitle: String {
            tr(
                en: "Sukurini is free and open source",
                ko: "Sukurini는 무료이고 오픈 소스예요",
                ja: "Sukurini は無料でオープンソースです"
            )
        }
        static var starDetail: String {
            tr(
                en: "A star on GitHub is how other people find it.",
                ko: "GitHub에 별을 하나 눌러 주시면 다른 사람도 찾을 수 있어요.",
                ja: "GitHub でスターを付けてもらえると、ほかの人にも見つけてもらえます。"
            )
        }
        static var starAction: String { tr(en: "Star on GitHub", ko: "GitHub에서 별 주기", ja: "GitHub でスターを付ける") }
        static var starThanks: String { tr(en: "Thank you!", ko: "고마워요!", ja: "ありがとうございます！") }

        static var continueAction: String { tr(en: "Continue", ko: "계속", ja: "続ける") }
        static var applyAndContinue: String { tr(en: "Apply and Continue", ko: "적용하고 계속", ja: "適用して続ける") }
        static var done: String { tr(en: "Done", ko: "완료", ja: "完了") }
        static var skip: String { tr(en: "Skip", ko: "건너뛰기", ja: "スキップ") }

        static func convertAction(_ count: String) -> String {
            tr(en: "Convert \(count) PNGs", ko: "PNG \(count)개 바꾸기", ja: "PNG \(count) 件を変換")
        }

        static func confirmDeleteTitle(_ count: String) -> String {
            tr(
                en: "Convert \(count) screenshots to WebP?",
                ko: "스크린샷 \(count)개를 WebP로 바꿀까요?",
                ja: "スクリーンショット \(count) 件を WebP に変換しますか？"
            )
        }
        static var confirmDeleteBody: String {
            tr(
                en: "The original PNGs are deleted permanently and cannot be recovered. Each file is verified pixel by pixel first.",
                ko: "원본 PNG는 완전히 지워져서 되살릴 수 없어요. 파일마다 픽셀 단위로 먼저 확인해요.",
                ja: "元の PNG は完全に削除され、元に戻せません。ファイルごとにピクセル単位で先に確認します。"
            )
        }
    }
}

extension L10n {
    enum Analytics {
        static var header: String { tr(en: "Privacy", ko: "개인정보", ja: "プライバシー") }
        static var enable: String {
            tr(
                en: "Anonymous Analytics (Telemetry)",
                ko: "익명 사용 통계 (텔레메트리)",
                ja: "匿名の利用統計（テレメトリ）"
            )
        }
        static var enableDetail: String {
            tr(
                en: "Counts only — which features get used, and how often.",
                ko: "어떤 기능을 얼마나 쓰는지, 숫자만 보내요.",
                ja: "どの機能をどれくらい使うか、数だけを送ります。"
            )
        }
        static var footer: String {
            tr(
                en: "Never sent: file names, folder paths, search words, or image contents. Counts are rounded into ranges, and no account or advertising identifier is attached. Crash reports are separate and keep working when this is off.",
                ko: "파일 이름, 폴더 경로, 검색어, 이미지 내용은 절대 보내지 않아요. 숫자는 구간으로 뭉뚱그려 보내고, 계정이나 광고 식별자도 붙지 않아요. 오류 보고는 따로라서 이걸 꺼도 계속 보내져요.",
                ja: "ファイル名、フォルダのパス、検索した言葉、画像の中身は一切送りません。件数は範囲にまるめて送り、アカウントや広告 ID も付きません。クラッシュ報告は別扱いで、これをオフにしても送られます。"
            )
        }
    }
}
