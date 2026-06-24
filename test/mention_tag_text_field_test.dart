import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mention_tag_text_field/src/mention_tag_decoration.dart';
import 'package:mention_tag_text_field/src/mention_tag_text_editing_controller.dart';

/// Recursively collects every leaf [InlineSpan] in [root].
List<InlineSpan> _flatten(InlineSpan root) {
  final out = <InlineSpan>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.children == null || span.children!.isEmpty) {
        out.add(span);
      } else {
        span.children!.forEach(walk);
      }
    } else {
      out.add(span);
    }
  }

  walk(root);
  return out;
}

void main() {
  late MentionTagTextEditingController controller;

  setUp(() {
    controller = MentionTagTextEditingController()
      ..mentionTagDecoration = const MentionTagDecoration()
      // onMention must be set or onChanged short-circuits.
      ..onMention = (_) {};
  });

  tearDown(() => controller.dispose());

  group('Android tap-selection fix', () {
    testWidgets(
      'a plain mention renders as an inline TextSpan, not a WidgetSpan, so '
      'tap hit-testing maps to the single escape-char offset',
      (tester) async {
        controller
          ..text = '@alice'
          ..initialMentions = const [('@alice', 'alice-id', null)];

        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final span = controller.buildTextSpan(
          context: ctx,
          style: const TextStyle(),
          withComposing: false,
        );

        final leaves = _flatten(span);
        expect(
          leaves.whereType<WidgetSpan>(),
          isEmpty,
          reason: 'mentions without a custom stylingWidget must be TextSpans',
        );
        expect(
          leaves.whereType<TextSpan>().any((s) => s.text == '@alice'),
          isTrue,
          reason: 'the mention label should be rendered as styled text',
        );
      },
    );

    testWidgets(
      'a mention with a custom stylingWidget still renders as a WidgetSpan',
      (tester) async {
        const chip = Text('CHIP');
        controller
          ..text = '@bob'
          ..initialMentions = const [('@bob', 'bob-id', chip)];

        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final span = controller.buildTextSpan(
          context: ctx,
          style: const TextStyle(),
          withComposing: false,
        );

        expect(_flatten(span).whereType<WidgetSpan>(), isNotEmpty);
      },
    );

    testWidgets(
      'buildTextSpan does not invoke onUrlsFound from the paint path',
      (tester) async {
        var called = false;
        controller.onUrlsFound = (_) {
          called = true;
        };
        controller.text = 'see https://example.com';

        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        controller.buildTextSpan(
          context: ctx,
          style: const TextStyle(),
          withComposing: false,
        );

        expect(
          called,
          isFalse,
          reason: 'URL callback must not fire during layout/paint',
        );
        // URLs are still tracked for the `urls` getter.
        expect(controller.urls, contains('https://example.com'));
      },
    );

    testWidgets(
      'onChanged fires onUrlsFound after the current frame',
      (tester) async {
        final found = <String>[];
        controller
          // URL detection runs before (and independently of) the mention path;
          // leave onMention null so onChanged returns right after notifying.
          ..onMention = null
          ..onUrlsFound = found.addAll;

        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

        controller.onChanged('visit https://example.com now');
        expect(found, isEmpty, reason: 'deferred to a post-frame callback');

        await tester.pump();
        expect(found, contains('https://example.com'));
      },
    );

    testWidgets(
      'with maxWords null, a multi-word candidate keeps flowing to onMention '
      'after a space (so the search overlay stays open for spaced names)',
      (tester) async {
        String? lastMention;
        controller
          ..mentionTagDecoration = const MentionTagDecoration(maxWords: null)
          ..onMention = (m) => lastMention = m;

        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

        // Type "@Derek Ross" with the caret at the end; a space mid-candidate
        // must NOT null out the mention when no word limit is set.
        controller
          ..text = '@Derek Ross'
          ..selection = const TextSelection.collapsed(offset: 11);
        controller.onChanged('@Derek Ross');

        expect(
          lastMention,
          '@Derek Ross',
          reason: 'maxWords == null must allow spaced multi-word candidates',
        );
      },
    );

    testWidgets(
      'with maxWords set, a space still ends the candidate (unchanged behavior)',
      (tester) async {
        String? lastMention;
        controller
          ..mentionTagDecoration = const MentionTagDecoration(maxWords: 1)
          ..onMention = (m) => lastMention = m;

        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

        controller
          ..text = '@Derek Ross'
          ..selection = const TextSelection.collapsed(offset: 11);
        controller.onChanged('@Derek Ross');

        expect(
          lastMention,
          isNull,
          reason: 'a word limit must still bail on a space',
        );
      },
    );

    test(
      'the selection listener ignores non-collapsed (range) selections '
      'while a mention is mid-edit',
      () {
        var mentionCallbacks = 0;
        controller.onMention = (_) => mentionCallbacks++;

        // Put a mention mid-edit so _indexMentionEnd is set and the listener
        // would normally re-run mention mutation on every selection change.
        controller.text = '@ca';
        controller.selection = const TextSelection.collapsed(offset: 3);
        controller.onChanged('@ca');
        final baseline = mentionCallbacks;

        // A tap that resolves to a range (the Android failure mode) must not
        // re-invoke the mention path — the listener bails on non-collapsed
        // selections.
        controller.selection = const TextSelection(
          baseOffset: 0,
          extentOffset: 3,
        );

        expect(controller.selection.isCollapsed, isFalse);
        expect(
          mentionCallbacks,
          baseline,
          reason: 'range selection must not trigger mention mutation',
        );
      },
    );
  });
}
