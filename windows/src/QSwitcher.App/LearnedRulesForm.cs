using QSwitcher.Core;

namespace QSwitcher.App;

/// <summary>
/// Редактор выученных правил: список с типом правила, правка и удаление
/// поштучно, добавление вручную.
///
/// Раньше здесь было окно с текстом и единственной кнопкой «сбросить всё» —
/// одно случайное правило приходилось сносить вместе со всеми остальными.
/// </summary>
public sealed class LearnedRulesForm : Form
{
    private readonly LearnedRules _rules;
    private readonly ListView _list;
    private readonly TextBox _newWord;
    private readonly ComboBox _newKind;

    private readonly Func<string,string> _swap;

    public LearnedRulesForm(LearnedRules rules, Func<string,string> swap)
    {
        _rules = rules;
        _swap = swap;

        Text = "QSwitcher — выученные правила";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(460, 420);
        MinimumSize = new Size(420, 320);

        _list = new ListView
        {
            View = View.Details,
            FullRowSelect = true,
            MultiSelect = true,
            HideSelection = false,
            Left = 12, Top = 12, Width = 436, Height = 280,
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom,
        };
        _list.Columns.Add("Слово", 130);
        _list.Columns.Add("Что произойдёт", 280);
        _list.DoubleClick += (_, _) => FlipSelected();
        _list.KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Delete) { DeleteSelected(); e.Handled = true; }
        };
        Controls.Add(_list);

        int y = 302;

        var flipBtn = new Button
        {
            Text = "Изменить", Left = 12, Top = y, Width = 100,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        flipBtn.Click += (_, _) => FlipSelected();
        Controls.Add(flipBtn);

        var delBtn = new Button
        {
            Text = "Удалить", Left = 118, Top = y, Width = 100,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        delBtn.Click += (_, _) => DeleteSelected();
        Controls.Add(delBtn);

        var resetBtn = new Button
        {
            Text = "Сбросить всё", Left = 328, Top = y, Width = 120,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
        };
        resetBtn.Click += (_, _) =>
        {
            if (MessageBox.Show("Удалить все правила?", "QSwitcher",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            {
                _rules.Reset();
                Reload();
            }
        };
        Controls.Add(resetBtn);

        y += 36;

        var addLabel = new Label
        {
            Text = "Добавить:", Left = 12, Top = y + 4, Width = 70,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        Controls.Add(addLabel);

        _newWord = new TextBox
        {
            Left = 84, Top = y, Width = 130,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        Controls.Add(_newWord);

        _newKind = new ComboBox
        {
            Left = 220, Top = y, Width = 160,
            DropDownStyle = ComboBoxStyle.DropDownList,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        _newKind.Items.AddRange(new object[] { "переключать", "оставлять как есть" });
        _newKind.SelectedIndex = 0;
        Controls.Add(_newKind);

        var addBtn = new Button
        {
            Text = "+", Left = 386, Top = y - 1, Width = 32,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left,
        };
        addBtn.Click += (_, _) =>
        {
            var w = _newWord.Text.Trim();
            if (w.Length == 0) return;
            _rules.Add(w, force: _newKind.SelectedIndex == 0);
            _newWord.Clear();
            Reload();
        };
        Controls.Add(addBtn);

        y += 34;
        var hint = new Label
        {
            Text = "Двойной клик по строке меняет правило на противоположное, Del удаляет.",
            Left = 12, Top = y, Width = 436, Height = 32,
            Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
        };
        Controls.Add(hint);

        Reload();
    }

    private void Reload()
    {
        _list.BeginUpdate();
        _list.Items.Clear();
        var (stop, force) = _rules.Snapshot();
        // Показываем направление целиком: «q → й» понятнее, чем просто «q».
        foreach (var w in force)
            _list.Items.Add(new ListViewItem(new[] { w, $"→ {_swap(w)}  (переключать)" }) { Tag = w });
        foreach (var w in stop)
            _list.Items.Add(new ListViewItem(new[] { w, "оставлять как есть" }) { Tag = w });
        _list.EndUpdate();
        Text = $"QSwitcher — выученные правила ({force.Count + stop.Count})";
    }

    private void FlipSelected()
    {
        foreach (ListViewItem item in _list.SelectedItems)
            if (item.Tag is string w) _rules.Flip(w);
        Reload();
    }

    private void DeleteSelected()
    {
        foreach (ListViewItem item in _list.SelectedItems)
            if (item.Tag is string w) _rules.Remove(w);
        Reload();
    }
}
