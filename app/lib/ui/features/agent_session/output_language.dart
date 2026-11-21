import 'dart:convert';

import '../../render/markdown/highlight/highlight.dart';

/// Tool output that reads as source code, and in which language: the name
/// `MdCodeBlock` highlights with, or null when the text reads as anything
/// else (a listing, progress lines, prose).
///
/// A piped command names no file, so only the text itself decides, in order:
///
/// 1. Whole-text JSON (parsed, not just balanced) and unified diffs have
///    exact shapes; diff line prefixes say so, no scoring.
/// 2. Otherwise every selective language scores the first lines by the
///    characters its scanner covers, and the best wins near half the text.
///    Near-identical scanners agree (C and C++ on a header), so the first of
///    the family names it; a listing every C-like scanner barely matches
///    stays plain.
/// 3. The greedy scanners sit out. YAML scalars match everything, shell
///    prompts match listings, CSS `name: value` matches bitfields and times
///    (`data_addr:36`, `12:39`), and the config and query DSLs key on
///    `word = value` / `word:` shapes that logs are full of - any of them
///    would win contests without saying anything. Their output stays plain.
///
/// Sampled lines keep it cheap; blank lines never count.
String? outputLanguage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (_isJson(trimmed)) return 'json';
  if (_isDiff(trimmed)) return 'diff';
  var chars = 0;
  var taken = 0;
  final sample = <String>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    sample.add(line.length <= _lineBudget ? line : line.substring(0, _lineBudget));
    chars += sample.last.length;
    if (++taken >= _lineSample) break;
  }
  if (chars < _minChars) return null;
  String? best;
  var bestCovered = 0;
  for (final name in _candidates) {
    final highlighter = highlighterFor(name);
    if (highlighter == null) continue;
    var state = highlighter.initial;
    var covered = 0;
    for (final line in sample) {
      final (tokens, next) = highlighter.line(line, state);
      state = next;
      for (final token in tokens) {
        covered += token.end - token.start;
      }
    }
    if (covered > bestCovered) {
      bestCovered = covered;
      best = name;
    }
  }
  if (best == null || bestCovered / chars < _coverage) return null;
  return best;
}

bool _isJson(String trimmed) {
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return false;
  try {
    jsonDecode(trimmed);
    return true;
  } on FormatException {
    return false;
  }
}

/// Every non-blank line is a diff line, a hunk header, or a file header.
bool _isDiff(String trimmed) {
  var lines = 0;
  for (final line in trimmed.split('\n')) {
    if (line.trim().isEmpty) continue;
    lines++;
    if (line.startsWith('@@') || line.startsWith('--- ') || line.startsWith('+++ ')) continue;
    final first = line[0];
    if (first != ' ' && first != '+' && first != '-') return false;
  }
  return lines > 0;
}

/// Lines looked at, longest line honored, smallest text considered.
const _lineSample = 60;
const _lineBudget = 400;
const _minChars = 20;

/// Covered characters over sampled characters that name a language.
const _coverage = 0.45;

const _candidates = ['cpp', 'c', 'dart', 'python', 'js', 'ts', 'rust', 'go', 'java', 'kotlin', 'swift', 'html'];
