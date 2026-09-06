import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/main_provider_setup.dart';
import 'package:neorecall/src/install/admin_provider_client.dart';

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
      backendUrl: 'http://server.test',
      apiKey: 'admin-key',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer admin-key');
        final path = request.url.path;
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
    );
    addTearDown(client.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.widgetWithText(TextField, 'Base URL'), findsOneWidget);
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
    expect(find.textContaining('Transcription: heard the sample'), findsOneWidget);
    expect(find.textContaining('Memory writing: the model refused'), findsOneWidget);
  });

  testWidgets('a missing base URL is refused before anything is sent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var writes = 0;
    final client = AdminProviderClient(
      backendUrl: 'http://server.test',
      apiKey: 'admin-key',
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
    );
    addTearDown(client.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
    expect(
      find.textContaining('needs a base URL'),
      findsOneWidget,
    );
  });
}
