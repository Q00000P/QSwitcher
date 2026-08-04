namespace QSwitcher.App;

/// <summary>
/// Окно настройки горячих клавиш. Каждое действие — строка с полем захвата:
/// кликнул, нажал желаемое сочетание, оно записалось.
///
/// Тап по модификатору задаётся так же: нажал и отпустил модификатор, ничего
/// больше не трогая — окно распознает это как тап.
/// </summary>
public sealed class HotkeySettingsForm : Form
{
    private readonly HotkeyMap _live;
    private readonly HotkeyMap _draft;
    private readonly Action _onSaved;

    public HotkeySettingsForm(HotkeyMap map, Action onSaved)
    {
        _live = map;
        // Правим КОПИЮ: раньше изменения попадали в конфиг сразу при захвате,
        // и «Отмена» ничего не отменяла — случайно нажатая клавиша оставалась.
        _draft = Clone(map);
        _onSaved = onSaved;

        Text = "QSwitcher — горячие клавиши";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 40 + 34 * 8 + 60);

        int y = 12;
        foreach (var (action, binding, title) in _draft.All())
        {
            var label = new Label
            {
                Text = title,
                Left = 16, Top = y + 4, Width = 220, AutoSize = false,
            };
            Controls.Add(label);

            var box = new CaptureBox(binding)
            {
                Left = 244, Top = y, Width = 250,
            };
            var captured = action;
            box.Captured += b => _draft.Set(captured, b);
            Controls.Add(box);

            y += 34;
        }

        var hint = new Label
        {
            Text = "Кликни в поле и нажми сочетание. Для «тапа» нажми и отпусти\n" +
                   "модификатор, ничего больше не трогая.",
            Left = 16, Top = y + 6, Width = 480, Height = 34,
        };
        Controls.Add(hint);

        var ok = new Button { Text = "Сохранить", Left = 316, Top = y + 44, Width = 90 };
        ok.Click += (_, _) =>
        {
            Apply(_draft, _live);
            _onSaved();
            Close();
        };
        Controls.Add(ok);

        var cancel = new Button { Text = "Отмена", Left = 412, Top = y + 44, Width = 82 };
        cancel.Click += (_, _) => Close();
        Controls.Add(cancel);
    }

    private static HotkeyMap Clone(HotkeyMap m) => new()
    {
        SwapWord = m.SwapWord,
        SwapAndLearn = m.SwapAndLearn,
        SwapSelection = m.SwapSelection,
        ChangeCase = m.ChangeCase,
        Translit = m.Translit,
        TogglePause = m.TogglePause,
        UndoLast = m.UndoLast,
        SwapWordAlt = m.SwapWordAlt,
    };

    private static void Apply(HotkeyMap from, HotkeyMap to)
    {
        to.SwapWord = from.SwapWord;
        to.SwapAndLearn = from.SwapAndLearn;
        to.SwapSelection = from.SwapSelection;
        to.ChangeCase = from.ChangeCase;
        to.Translit = from.Translit;
        to.TogglePause = from.TogglePause;
        to.UndoLast = from.UndoLast;
        to.SwapWordAlt = from.SwapWordAlt;
    }

    /// <summary>Поле, которое ловит нажатое сочетание.</summary>
    private sealed class CaptureBox : TextBox
    {
        private HotkeyBinding _binding;
        private uint _pendingModifier;
        private bool _sawOtherKey;

        public event Action<HotkeyBinding>? Captured;

        public CaptureBox(HotkeyBinding initial)
        {
            _binding = initial;
            ReadOnly = true;
            Text = initial.Display;
            TextAlign = HorizontalAlignment.Center;
            Cursor = Cursors.Hand;
        }

        protected override bool IsInputKey(Keys keyData) => true;

        protected override void OnKeyDown(KeyEventArgs e)
        {
            e.SuppressKeyPress = true;
            uint vk = (uint)e.KeyCode;

            if (HotkeyDetector.IsTrackableModifier(vk) || vk is 0x11 or 0x12)
            {
                _pendingModifier = NormalizeModifier(vk, e);
                _sawOtherKey = false;
                return;
            }
            if (vk is 0x10 or 0xA0 or 0xA1) return;   // Shift сам по себе не клавиша

            _sawOtherKey = true;
            Apply(new HotkeyBinding
            {
                Key = vk,
                Shift = e.Shift,
                Modifier = _pendingModifier,
                IsTap = false,
            });
        }

        protected override void OnKeyUp(KeyEventArgs e)
        {
            e.SuppressKeyPress = true;
            uint vk = (uint)e.KeyCode;
            if (!HotkeyDetector.IsTrackableModifier(vk) && vk is not (0x11 or 0x12)) return;
            if (_sawOtherKey || _pendingModifier == 0) { _pendingModifier = 0; return; }

            // Модификатор нажали и отпустили, ничего не задев — это тап.
            // Сторону берём из _pendingModifier, определённую при НАЖАТИИ:
            // на отпускании клавиша уже не нажата, и проверка «нажат ли правый»
            // всегда давала ложь — поэтому правый Ctrl записывался как левый.
            Apply(new HotkeyBinding
            {
                Key = _pendingModifier,
                Shift = e.Shift,
                IsTap = true,
            });
            _pendingModifier = 0;
        }

        /// WinForms отдаёт общий VK_CONTROL — сторону уточняем пока клавиша НАЖАТА.
        private static uint NormalizeModifier(uint vk, KeyEventArgs e)
        {
            if (vk == 0x11) // VK_CONTROL
                return (GetKeyState(0xA3) & 0x8000) != 0 ? 0xA3u : 0xA2u;
            if (vk == 0x12) // VK_MENU
                return (GetKeyState(0xA5) & 0x8000) != 0 ? 0xA5u : 0xA4u;
            if (vk == 0x10) // VK_SHIFT
                return (GetKeyState(0xA1) & 0x8000) != 0 ? 0xA1u : 0xA0u;
            return vk;
        }

        private void Apply(HotkeyBinding b)
        {
            _binding = b;
            Text = b.Display;
            Captured?.Invoke(b);
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern short GetKeyState(int nVirtKey);
    }
}
