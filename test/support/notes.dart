// A seeded Markdown note generator. Each task line is built from parts, so
// tests can predict the exact bytes of every documented edit.
import 'dart:math';

/// One inline field, such as ` 📅 2027-04-12`.
class Token {
  const Token(this.emoji, this.value, [this.before = ' ', this.between = ' ']);
  final String emoji, value, before, between;
  bool get simple => before == ' ' && between == ' ';
  String get text => '$before$emoji$between$value';
}

/// A task in the documented field order: 🎯 ➕ ⏳ 📅 ✅ 🆔, with priority, 🔁 and 🛫
/// fields mixed in at any position, then an optional Obsidian block ID and
/// trailing whitespace.
class TaskLine {
  const TaskLine(this.prefix, this.check, this.gap, this.title, this.tokens, this.suffix);
  final String prefix; // Indent, bullet and spacing before `[`.
  final String check;
  final String gap; // Whitespace between `]` and a non-empty title.
  final String title;
  final List<Token> tokens;
  final String suffix; // Block ID and trailing whitespace.

  Token? field(String emoji) => tokens.where((t) => t.emoji == emoji).firstOrNull;
  bool get done => check == 'x' || check == 'X';
  String? get recurrence => field('🔁')?.value;
  String? get priority => switch (tokens.where((t) => _priorities.containsKey(t.emoji)).firstOrNull) {
    final t? => _priorities[t.emoji],
    null => null,
  };
  String? get due => field('📅')?.value;
  bool get taskForge => field('➕') != null && field('🆔') != null;
  String get text =>
      '$prefix[$check]${title.isEmpty ? '' : '$gap$title'}${tokens.map((t) => t.text).join()}$suffix';

  TaskLine _with({String? check, required List<Token> tokens}) =>
      TaskLine(prefix, check ?? this.check, gap, title, tokens, suffix);

  /// Moves the date in place, removes it, or inserts it before ✅, 🆔 or the
  /// block ID, as the README and reference review document.
  TaskLine withDue(String? date) {
    final next = [...tokens];
    final index = next.indexWhere((t) => t.emoji == '📅');
    if (index != -1) {
      final old = next[index];
      if (date == null) {
        next.removeAt(index);
      } else {
        next[index] = Token('📅', date, old.before, old.between);
      }
    } else if (date != null) {
      final at = next.indexWhere((t) => t.emoji == '✅' || t.emoji == '🆔');
      next.insert(at == -1 ? next.length : at, Token('📅', date));
    }
    return _with(tokens: next);
  }

  /// Toggles the checkbox. TaskForge tasks also gain or lose ` ✅ day` before 🆔.
  TaskLine withCompletion(bool value, String day) {
    if (done == value) return this;
    final next = [...tokens];
    if (taskForge) {
      final index = next.indexWhere((t) => t.emoji == '✅');
      if (value && index == -1) {
        next.insert(next.indexWhere((t) => t.emoji == '🆔'), Token('✅', day));
      } else if (!value && index != -1) {
        next.removeAt(index);
      }
    }
    return _with(check: value ? 'x' : ' ', tokens: next);
  }
}

class Line {
  const Line(this.text, this.ending, [this.task]);
  final String text;
  final String ending;
  final TaskLine? task;
}

/// Lines that only make sense together, such as a fence and its contents.
/// Lines of a `list` or `text` block can be removed independently.
class Block {
  const Block(this.kind, this.lines);
  final String kind; // front, fence, open-fence, list or text.
  final List<Line> lines;
}

class Note {
  const Note(this.bom, this.blocks, this.finalBreak);
  final bool bom;
  final List<Block> blocks;
  final bool finalBreak;

  List<Line> get lines => [for (final block in blocks) ...block.lines];
  bool get unclosed => blocks.isNotEmpty && blocks.last.kind == 'open-fence';

  String get text {
    final all = lines;
    final out = StringBuffer(bom ? '\uFEFF' : '');
    for (var i = 0; i < all.length; i++) {
      final last = i == all.length - 1;
      var ending = last && !finalBreak ? '' : all[i].ending;
      // A lone CR before an empty LF line would read as one CRLF break.
      if (ending == '\r' && !last && all[i + 1].text.isEmpty &&
          (i + 1 < all.length - 1 || finalBreak) && all[i + 1].ending.startsWith('\n')) {
        ending = '\r\n';
      }
      out..write(all[i].text)..write(ending);
    }
    return out.toString();
  }

  /// Smaller notes that keep [keep], for shrinking a failing case.
  Iterable<Note> smaller(Line? keep) sync* {
    if (bom) yield Note(false, blocks, finalBreak);
    for (var b = 0; b < blocks.length; b++) {
      if (!blocks[b].lines.contains(keep)) {
        yield Note(bom, [...blocks.take(b), ...blocks.skip(b + 1)], finalBreak);
      }
    }
    for (var b = 0; b < blocks.length; b++) {
      final block = blocks[b];
      if (block.kind != 'list' && block.kind != 'text') continue;
      for (final line in block.lines) {
        if (line == keep || block.lines.length == 1) continue;
        final rest = Block(block.kind, [...block.lines.where((l) => l != line)]);
        yield Note(bom, [...blocks.take(b), rest, ...blocks.skip(b + 1)], finalBreak);
      }
    }
  }
}

// Words that may end a title. None of them reads as a field or block ID.
const _plain = [
  'Draft', 'map', 'Résumé', 'naïve', 'café', 'Zoë', '日本語', 'Привет', 'مرحبا',
  'שלום', '提出', '🎉', '🚀', '👩\u200D💻', '👍🏽', '🇺🇦', 'e\u0301clair', '𝔘𝔫𝔦', 'ﬁle',
  '#tag', '[[Link|alias]]', '**bold**', '`code`', '🔁', 'x', '42', 'v1.2',
  '(a)', '"quoted"', 'a]b', '⏳⏳',
];
// Prose that looks like metadata but sits mid-title, so it stays in the title.
const _prose = [
  '📅', '🎯', '✅', '🆔', '➕', '⏳', '📅 2027-02-30', '📅 2027-01-01', '🎯 9:00AM',
  '✅ 2027-01-01', '🆔 abc', '^caret', '- [ ]', '[x]', '📅\u00A02027-01-01', '⏳ 2026-13-01',
  ...lineSeparators,
];
const _priorities = {'🔺': 'highest', '⏫': 'high', '🔼': 'medium', '🔽': 'low', '⏬': 'lowest'};
const _rules = ['every week', 'every 2 days', 'every month on the 1st', 'every weekday when done'];
// Unicode line and paragraph separators. Markdown keeps them inside a line,
// so they belong to the title. Dart's trim() removes them, so they appear only
// mid-title, where a capture keeps them too.
const lineSeparators = ['\u2028', '\u2029'];

class NoteGenerator {
  NoteGenerator(int seed) : random = Random(seed);
  final Random random;
  String _style = 'lf';

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];
  bool chance(double p) => random.nextDouble() < p;

  String date() {
    final year = 2000 + random.nextInt(100), month = 1 + random.nextInt(12);
    final days = DateTime.utc(year, month + 1, 0).day;
    final day = 1 + random.nextInt(days);
    return '$year-${'$month'.padLeft(2, '0')}-${'$day'.padLeft(2, '0')}';
  }

  String ending() => switch (_style) {
    'lf' => '\n', 'crlf' => '\r\n', 'cr' => '\r', _ => pick(['\n', '\r\n', '\r']),
  };

  /// A non-empty title that parses back unchanged.
  String title() {
    final count = 1 + random.nextInt(5);
    final words = [
      for (var i = 0; i < count; i++)
        i >= count - 2 || !chance(0.35) ? pick(_plain) : pick(_prose),
    ];
    final out = StringBuffer(words.first);
    for (final word in words.skip(1)) {
      out..write(pick([' ', ' ', ' ', ' ', '\t', '  ', '\u00A0']))..write(word);
    }
    return out.toString();
  }

  String _time() => pick(['9:00AM', '9:00AM-9:30AM', '12:45PM', '10:05AM-11:00AM', '1:00PM-12:59PM']);
  String _id() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final id = [for (var i = 0; i < 4 + random.nextInt(6); i++) chars[random.nextInt(chars.length)]].join();
    return chance(0.2) ? '$id-${random.nextInt(99)}_x' : id;
  }

  Token _token(String emoji, String value) => Token(emoji, value,
      pick([' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', '\t', '  ']),
      pick([' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', '\t', '  ']));

  TaskLine task(String indent) {
    final check = pick([' ', ' ', ' ', ' ', 'x', 'x', 'x', 'X', '-', '/', '!', '>', '~', '#', '?', '*']);
    final done = check != ' ';
    final prefix = '$indent${pick(['-', '-', '*', '+'])}${pick([' ', ' ', ' ', '\t', '  '])}';
    final style = random.nextInt(10);
    final fields = <String, String>{};
    if (style < 4) {
      if (chance(0.5)) fields['📅'] = date();
    } else if (style < 6) {
      // Obsidian Tasks style: dates without a TaskForge ID.
      if (chance(0.3)) fields['➕'] = date();
      if (chance(0.3)) fields['⏳'] = date();
      if (chance(0.6)) fields['📅'] = date();
      if (done && chance(0.5)) fields['✅'] = date();
      if (chance(0.1)) fields['🆔'] = _id();
    } else {
      if (chance(0.3)) fields['🎯'] = _time();
      fields['➕'] = date();
      if (chance(0.4)) fields['⏳'] = date();
      if (chance(0.6)) fields['📅'] = date();
      if (done && chance(0.75)) fields['✅'] = date();
      fields['🆔'] = _id();
    }
    final tokens = [
      for (final emoji in ['🎯', '➕', '⏳', '📅', '✅', '🆔'])
        if (fields[emoji] case final value?) _token(emoji, value),
    ];
    // TaskForge also writes priority, recurrence and start dates. Their position
    // is not fixed, so they go anywhere in the run.
    void mixIn(Token token) => tokens.insert(random.nextInt(tokens.length + 1), token);
    if (chance(0.2)) mixIn(Token(pick(_priorities.keys.toList()), '', pick([' ', ' ', '\t']), ''));
    if (chance(0.12)) mixIn(_token('🔁', pick(_rules)));
    if (chance(0.12)) mixIn(_token('🛫', date()));
    final empty = chance(0.06);
    final block = chance(0.25) ? '${pick([' ', ' ', '\t'])}^${_id().replaceAll('_', '')}' : '';
    final trailing = chance(0.15) ? pick([' ', '  ', '\t']) : '';
    return TaskLine(prefix, check, pick([' ', ' ', ' ', '\t', '  ', ' \t']),
        empty ? '' : title(), tokens, '$block$trailing');
  }

  Block _list() {
    final lines = <Line>[];
    final indents = [''];
    for (var i = 0; i < 1 + random.nextInt(6); i++) {
      if (i > 0 && chance(0.35)) {
        indents.add(indents.last + pick(['  ', '    ', '\t', '\t']));
      } else if (indents.length > 1 && chance(0.3)) {
        indents.removeLast();
      }
      final indent = indents.last;
      final roll = random.nextInt(20);
      if (roll < 15) {
        final task = this.task(indent);
        lines.add(Line(task.text, ending(), task));
      } else if (roll < 17) {
        lines.add(Line('$indent- Note ${title()}', ending()));
      } else {
        // Near misses that are not supported checkboxes.
        lines.add(Line(indent + pick([
          '-[ ] no space after the bullet', '- [ ]glued', '- [y] other status', '- [xx] two marks',
          '1. [ ] ordered item', '- [x]x', '[ ] no bullet', '- [  ] two spaces', 'Task: - [ ] inline',
        ]), ending()));
      }
    }
    return Block('list', lines);
  }

  Block _text() => Block('text', [
    for (var i = 0; i < 1 + random.nextInt(3); i++)
      Line(pick([
        '', '', '   ', '# Heading 🌍 Ünïcode', '## Week 47 — plan', '***', '* * *', '___',
        'Paragraph with - [ ] inline text and 📅 2027-01-01 mid-sentence.',
        '> Quote with a date 📅 2027-01-01', '| a | b |', '<!-- comment -->', 'Wrap^line',
      ]), ending()),
  ]);

  Block _fence(bool open) {
    final char = chance(0.5) ? '`' : '~';
    final length = 3 + (chance(0.25) ? 1 : 0);
    final run = char * length;
    final lines = [
      Line('${' ' * random.nextInt(4)}$run${pick(['', 'md', ' markdown', 'js'])}', ending()),
      for (var i = 0; i < 1 + random.nextInt(4); i++)
        Line(pick([
          '- [ ] Fenced task 📅 2027-01-01', '* [x] Done in code', '  + [ ] Nested sample ^ref',
          '- [ ] Fenced ➕ 2026-11-19 🆔 abc', 'print("- [ ] not a task");', '',
          '${char == '`' ? '~~~' : '```'} other fence char', '$run info does not close',
          if (length == 4) char * 3,
        ]), ending()),
    ];
    if (!open) {
      lines.add(Line('${' ' * random.nextInt(4)}${char * (length + random.nextInt(2))}'
          '${pick(['', '', ' ', '\t'])}', ending()));
    }
    return Block(open ? 'open-fence' : 'fence', lines);
  }

  Block _frontMatter() => Block('front', [
    Line(pick(['---', '---', '--- ']), ending()),
    for (var i = 0; i < 1 + random.nextInt(4); i++)
      Line(pick([
        'title: Ünïcode plan 🚀', 'tags: [work, "- [ ] not a task"]', '- [ ] YAML list item',
        '  - [x] nested YAML item', 'due: 2027-01-01', '```', 'note: |', '  ~~~',
      ]), ending()),
    Line(pick(['---', '---', '...']), ending()),
  ]);

  Note note() {
    _style = pick(['lf', 'lf', 'crlf', 'cr', 'mixed', 'mixed']);
    final blocks = <Block>[
      if (chance(0.3)) _frontMatter(),
      ...List.generate(1 + random.nextInt(6), (_) =>
          switch (random.nextInt(10)) { < 6 => _list(), < 8 => _text(), _ => _fence(false) }),
      if (chance(0.08)) _fence(true),
    ];
    return Note(chance(0.2), blocks, chance(0.75));
  }

  /// A note with at least [count] tasks and no open fence, for large vaults.
  Note withTasks(int count) {
    _style = pick(['lf', 'lf', 'lf', 'crlf', 'mixed']);
    final blocks = <Block>[if (chance(0.3)) _frontMatter()];
    for (var tasks = 0; tasks < count;) {
      final block = switch (random.nextInt(10)) { < 7 => _list(), < 9 => _text(), _ => _fence(false) };
      tasks += block.lines.where((l) => l.task != null).length;
      blocks.add(block);
    }
    return Note(chance(0.1), blocks, true);
  }
}

/// A Dart string literal for [text] that shows invisible characters.
String literal(String text) {
  final out = StringBuffer("'");
  for (final rune in text.runes) {
    out.write(switch (rune) {
      0x5c => r'\\', 0x27 => r"\'", 0x24 => r'\$', 0x0a => r'\n', 0x0d => r'\r', 0x09 => r'\t',
      < 0x20 || 0xa0 || 0x200d || 0x2028 || 0x2029 || 0xfeff => '\\u{${rune.toRadixString(16)}}',
      _ => String.fromCharCode(rune),
    });
  }
  return (out..write("'")).toString();
}
