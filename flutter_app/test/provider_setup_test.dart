import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/main_provider_setup.dart';
import 'package:neorecall/src/admin/admin_provider_client.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

Map<String, dynamic> _settings({
  String transcriptionProvider = 'openai-compatible',
  String? transcriptionModel,
  bool transcriptionKey = false,
}) => <String, dynamic>{
  'transcription': <String, dynamic>{
    'provider': transcriptionProvider,
    'label': 'Custom OpenAI-compatible',
    'model': transcriptionModel,
    'baseUrl': 'http://127.0.0.1:9/v1',
    'apiKeyConfigured': transcriptionKey,
    'apiKeySource': transcriptionKey ? 'admin' : 'none',
  },
  'llm': <String, dynamic>{
    'provider': 'openai',
    'label': 'OpenAI',
    'model': 'gpt-4o-mini',
    'baseUrl': 'https://api.openai.com/v1',
    'apiKeyConfigured': true,
    'apiKeySource': 'admin',
  },
  'catalogs': <String, dynamic>{
    'transcription': <Map<String, dynamic>>[
      {
        'id': 'openai',
        'label': 'OpenAI',
        'protocol': 'openai',
        'defaultBaseUrl': 'https://api.openai.com/v1',
        'defaultModel': null,
        'apiKeyRequired': true,
        'modelOptional': false,
      },
      {
        'id': 'openai-compatible',
        'label': 'Custom OpenAI-compatible',
        'protocol': 'openai',
        'defaultBaseUrl': null,
        'defaultModel': null,
        'apiKeyRequired': false,
        'modelOptional': true,
      },
    ],
    'llm': <Map<String, dynamic>>[
      {
        'id': 'openai',
        'label': 'OpenAI',
        'protocol': 'openai',
        'defaultBaseUrl': 'https://api.openai.com/v1',
        'defaultModel': null,
        'apiKeyRequired': true,
        'modelOptional': false,
      },
    ],
  },
};

void main() {
  testWidgets('saving providers sends what the operator typed', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final requests = <String, Map<String, dynamic>>{};
    final client = AdminProviderClient(
      NeoRecallApiClient(
        baseUrl: 'http://server.test',
        token: 'session-token',
        client: MockClient((request) async {
          // The signed-in admin's own session, not a separate admin key.
          expect(request.headers['Authorization'], 'Bearer session-token');
          final path = request.url.path;
          expect(path, startsWith('/api/v1/admin/provider-settings'));
          if (request.method == 'GET' && path.endsWith('/provider-settings')) {
            return http.Response(
              jsonEncode(<String, dynamic>{'settings': _settings()}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (request.method == 'PUT' && path.endsWith('/provider-settings')) {
            requests['put'] = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'settings': _settings(
                  transcriptionModel: 'whisper-stub',
                  transcriptionKey: true,
                ),
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' && path.endsWith('/test')) {
            requests['test'] = <String, dynamic>{};
            return http.Response(
              jsonEncode(<String, dynamic>{
                'transcription': {'ok': true, 'text': 'heard the sample'},
                'speakerIdentity': {'ok': true, 'detail': 'models installed'},
                'llm': {'ok': false, 'error': 'the model refused'},
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        }),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProviderSetupPanel(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Transcription'), findsOneWidget);
    expect(find.text('Memory writing'), findsOneWidget);

    // A custom endpoint has no default base URL, so the form asks for one.
    expect(
      find.widgetWithText(TextField, 'Base URL or full transcription endpoint'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Model (optional)'),
      'whisper-stub',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'API key').first,
      'secret-key',
    );

    await tester.ensureVisible(find.text('Save and test'));
    await tester.tap(find.text('Save and test'));
    await tester.pumpAndSettle();

    final put = requests['put']!;
    expect(put['transcription']['provider'], 'openai-compatible');
    expect(put['transcription']['model'], 'whisper-stub');
    expect(put['transcription']['apiKey'], 'secret-key');
    expect(put['llm']['provider'], 'openai');
    expect(requests.containsKey('test'), isTrue);

    expect(find.textContaining('Saved.'), findsOneWidget);
    expect(
      find.textContaining('Transcription: heard the sample'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Memory writing: the model refused'),
      findsOneWidget,
    );
  });

  testWidgets('a missing base URL is refused before anything is sent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var writes = 0;
    final client = AdminProviderClient(
      NeoRecallApiClient(
        baseUrl: 'http://server.test',
        token: 'session-token',
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'settings': <String, dynamic>{
                  ..._settings(),
                  'transcription': <String, dynamic>{
                    ..._settings()['transcription'] as Map<String, dynamic>,
                    'baseUrl': null,
                  },
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          writes += 1;
          return http.Response('{}', 200);
        }),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProviderSetupPanel(client: client),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save only'));
    await tester.tap(find.text('Save only'));
    await tester.pumpAndSettle();

    expect(writes, 0);
    expect(find.textContaining('needs a base URL'), findsOneWidget);
  });

  testWidgets(
    'saving keeps the values the form leaves folded away, and the thinking switch edits the JSON',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Map<String, dynamic>? put;
      final stored = <String, dynamic>{
        ..._settings(transcriptionModel: 'whisper-stub'),
        'transcription': <String, dynamic>{
          ..._settings(transcriptionModel: 'whisper-stub')['transcription']
              as Map<String, dynamic>,
          'language': 'de',
          'responseFormat': 'verbose_json',
          'sources': <String, dynamic>{
            'language': 'admin',
            'responseFormat': 'admin',
          },
        },
        'llm': <String, dynamic>{
          ..._settings()['llm'] as Map<String, dynamic>,
          'extraBody': <String, dynamic>{'top_p': 0.9},
          'sources': <String, dynamic>{'extraBody': 'admin'},
        },
      };
      final client = AdminProviderClient(
        NeoRecallApiClient(
          baseUrl: 'http://server.test',
          token: 'session-token',
          client: MockClient((request) async {
            if (request.method == 'PUT') {
              put = jsonDecode(request.body) as Map<String, dynamic>;
            }
            return http.Response(
              jsonEncode(<String, dynamic>{'settings': stored}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProviderSetupPanel(client: client),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Saved untouched: a language and extra request fields set earlier must
      // survive a save from a form that never showed them.
      await tester.ensureVisible(find.text('Save only'));
      await tester.tap(find.text('Save only'));
      await tester.pumpAndSettle();
      expect(put!['transcription']['language'], 'de');
      expect(put!['transcription']['responseFormat'], 'verbose_json');
      expect(put!['llm']['extraBody'], <String, dynamic>{'top_p': 0.9});

      await tester.ensureVisible(find.text('Advanced').last);
      await tester.tap(find.text('Advanced').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Skip the model’s thinking step'));
      await tester.tap(find.text('Skip the model’s thinking step'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save only'));
      await tester.tap(find.text('Save only'));
      await tester.pumpAndSettle();
      expect(put!['llm']['extraBody'], <String, dynamic>{
        'top_p': 0.9,
        'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
      });
    },
  );

  testWidgets(
    'values from the server configuration are not frozen, and a typed key replaces a saved one',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Map<String, dynamic>? put;
      final stored = <String, dynamic>{
        ..._settings(transcriptionModel: 'whisper-stub'),
        'transcription': <String, dynamic>{
          ..._settings(transcriptionModel: 'whisper-stub')['transcription']
              as Map<String, dynamic>,
          'language': 'de',
          'responseFormat': 'verbose_json',
          'sources': <String, dynamic>{
            'language': 'environment',
            'responseFormat': 'default',
          },
        },
        'llm': <String, dynamic>{
          ..._settings()['llm'] as Map<String, dynamic>,
          'extraBody': <String, dynamic>{'top_p': 0.9},
          'environmentApiKeyConfigured': true,
          'sources': <String, dynamic>{'extraBody': 'environment'},
        },
      };
      final client = AdminProviderClient(
        NeoRecallApiClient(
          baseUrl: 'http://server.test',
          token: 'session-token',
          client: MockClient((request) async {
            if (request.method == 'PUT') {
              put = jsonDecode(request.body) as Map<String, dynamic>;
            }
            return http.Response(
              jsonEncode(<String, dynamic>{'settings': stored}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProviderSetupPanel(client: client),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save only'));
      await tester.tap(find.text('Save only'));
      await tester.pumpAndSettle();
      // Sent as null: the server keeps reading these from its .env.
      expect(put!['transcription']['language'], isNull);
      expect(put!['transcription']['responseFormat'], isNull);
      expect(put!['llm']['extraBody'], isNull);

      // Removing the saved key is allowed because the server has its own.
      await tester.ensureVisible(find.text('Advanced').last);
      await tester.tap(find.text('Advanced').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Remove the key saved here'));
      await tester.tap(find.text('Remove the key saved here'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save only'));
      await tester.tap(find.text('Save only'));
      await tester.pumpAndSettle();
      expect(put!['llm']['clearApiKey'], isTrue);
      expect(put!['llm'].containsKey('apiKey'), isFalse);

      // With the box ticked and a new key typed, the new key wins.
      await tester.ensureVisible(find.text('Remove the key saved here'));
      await tester.tap(find.text('Remove the key saved here'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .widgetWithText(
              TextField,
              'API key (leave empty to keep the stored one)',
            )
            .last,
        'sk-new',
      );
      await tester.ensureVisible(find.text('Save only'));
      await tester.tap(find.text('Save only'));
      await tester.pumpAndSettle();
      expect(put!['llm']['apiKey'], 'sk-new');
      expect(put!['llm'].containsKey('clearApiKey'), isFalse);
    },
  );
}
