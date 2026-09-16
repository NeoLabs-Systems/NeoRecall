import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/settings/destructive_confirm_dialog.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

Future<void> _open(
  WidgetTester tester, {
  required bool twoFactorEnabled,
  required Future<String?> Function({
    required String password,
    String? twoFactorCode,
  })
  onConfirm,
  List<String> kept = const <String>[],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      theme: buildNeoRecallTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => DestructiveConfirmDialog.show(
              context,
              username: 'frank',
              twoFactorEnabled: twoFactorEnabled,
              onConfirm: onConfirm,
              title: 'Delete your account',
              intro: 'This removes everything, permanently.',
              erased: const <String>[
                'Every transcript, conversation and memory',
                'Named speakers and their voice profiles',
                'Recordings still waiting to upload on this device',
              ],
              kept: kept,
              confirmLabel: 'Delete permanently',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder get _deleteButton =>
    find.widgetWithText(FilledButton, 'Delete permanently');
bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_deleteButton).onPressed != null;

void main() {
  testWidgets(
    'the destructive action stays disabled until every check is met',
    (tester) async {
      var called = false;
      await _open(
        tester,
        twoFactorEnabled: false,
        onConfirm: ({required password, twoFactorCode}) async {
          called = true;
          return null;
        },
      );

      expect(_enabled(tester), isFalse, reason: 'nothing entered yet');

      await tester.enterText(
        find.widgetWithText(TextField, 'Your password'),
        'correct horse',
      );
      await tester.pumpAndSettle();
      expect(_enabled(tester), isFalse, reason: 'password alone is not enough');

      await tester.enterText(
        find.widgetWithText(TextField, 'Type frank to confirm'),
        'frankie',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester),
        isFalse,
        reason: 'a near-miss username must not pass',
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Type frank to confirm'),
        'FRANK',
      );
      await tester.pumpAndSettle();
      expect(
        _enabled(tester),
        isTrue,
        reason: 'confirmation is case-insensitive',
      );

      await tester.tap(_deleteButton);
      await tester.pumpAndSettle();
      expect(called, isTrue);
    },
  );

  testWidgets('a 2FA account cannot confirm without a code', (tester) async {
    await _open(
      tester,
      twoFactorEnabled: true,
      onConfirm: ({required password, twoFactorCode}) async => null,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Your password'),
      'pw',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Type frank to confirm'),
      'frank',
    );
    await tester.pumpAndSettle();
    expect(
      _enabled(tester),
      isFalse,
      reason: 'the authenticator code is still missing',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Authenticator code'),
      '123456',
    );
    await tester.pumpAndSettle();
    expect(_enabled(tester), isTrue);
  });

  testWidgets('a failure is shown in the dialog and the dialog stays open', (
    tester,
  ) async {
    await _open(
      tester,
      twoFactorEnabled: false,
      onConfirm: ({required password, twoFactorCode}) async =>
          'That password is not correct.',
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Your password'),
      'wrong',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Type frank to confirm'),
      'frank',
    );
    await tester.pumpAndSettle();
    await tester.tap(_deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(
      _deleteButton,
      findsOneWidget,
      reason: 'the user can correct the password and retry',
    );
    expect(
      _enabled(tester),
      isTrue,
      reason: 'the button is usable again after a failure',
    );
  });

  testWidgets('the consequences are named, not summarised', (tester) async {
    await _open(
      tester,
      twoFactorEnabled: false,
      onConfirm: ({required password, twoFactorCode}) async => null,
    );
    expect(find.textContaining('voice profiles'), findsOneWidget);
    expect(find.textContaining('waiting to upload'), findsOneWidget);
  });

  testWidgets('what survives is named too, so the two actions cannot be '
      'mistaken for each other', (tester) async {
    await _open(
      tester,
      twoFactorEnabled: false,
      kept: const <String>['Your account, password and security keys'],
      onConfirm: ({required password, twoFactorCode}) async => null,
    );
    expect(find.textContaining('voice profiles'), findsOneWidget);
    expect(
      find.textContaining('Your account, password and security keys'),
      findsOneWidget,
    );
    // Removed and kept are marked differently, not just listed together.
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNWidgets(3));
  });

  testWidgets('cancelling reports that nothing was deleted', (tester) async {
    var confirmed = false;
    await _open(
      tester,
      twoFactorEnabled: false,
      onConfirm: ({required password, twoFactorCode}) async {
        confirmed = true;
        return null;
      },
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);
    expect(find.text('Delete your account'), findsNothing);
  });
}
