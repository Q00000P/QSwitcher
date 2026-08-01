cask "autoswitcher" do
  version "0.7"
  sha256 "ЗАМЕНИ_НА_SHA256_ИЗ_make-release.sh"

  url "https://github.com/Q00000P/AutoSwitcher/releases/download/v#{version}/AutoSwitcher-#{version}.zip"
  name "AutoSwitcher"
  desc "Автопереключатель раскладки клавиатуры RU↔EN"
  homepage "https://github.com/Q00000P/AutoSwitcher"

  # Снимаем карантин чтобы ad-hoc подписанное приложение запускалось без блокировки
  app "AutoSwitcher.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/AutoSwitcher.app"],
                   sudo: false
  end

  uninstall quit: "local.AutoSwitcher"

  zap trash: [
    "~/Library/Application Support/AutoSwitcher",
    "~/Library/Logs/AutoSwitcher.log",
    "~/Library/Logs/AutoSwitcher",
  ]

  caveats <<~EOS
    После установки нужно выдать AutoSwitcher права Accessibility:
    Системные настройки → Конфиденциальность и безопасность → Универсальный доступ →
    добавить AutoSwitcher и включить галку, затем перезапустить приложение.
  EOS
end
