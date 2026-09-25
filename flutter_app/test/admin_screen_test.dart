import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/main_admin.dart';
import 'package:neorecall/main_controller.dart';
import 'package:neorecall/main_navigation.dart';
import 'package:neorecall/main_theme.dart';
import 'package:neorecall/src/api_client.dart';
import 'package:neorecall/l10n/gen/app_l10n.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

final Map<String, dynamic> _stats = <String, dynamic>{
  'version': '9.9.9',
  'users': 2,
  'devices': 1,
  'recordings': 4,
  'queue': <Map<String, dynamic>>[
    <String, dynamic>{'status': 'queued', 'count': 3},
    <String, dynamic>{'status': 'failed', 'count': 2},
  ],
  'oldestQueuedAt': null,
  'workers': <Map<String, dynamic>>[],
  'temporaryAudioBytes': 0,
  'cleanupPending': 0,
  'vector': <String, dynamic>{'ready': true, 'version': '0.1.6'},
  'ai': <Map<String, dynamic>>[],
  'processing': <Map<String, dynamic>>[],
};

final Map<String, dynamic> _backups = <String, dynamic>{
  'status': <String, dynamic>{
    'enabled': true,
    'destination': 'local',
    'location': '/srv/backups',
    'unreachable': null,
    'intervalHours': 24,
    'retain': 3,
    'running': false,
    'due': false,
    'nextDueAt': null,
    'last': null,
    'lastSuccessAt': null,
    'artifactCount': 0,
    'artifactBytes': 0,
  },
  'history': <Map<String, dynamic>>[],
};

final Map<String, dynamic> _usage = <String, dynamic>{
  'limits': <String, dynamic>{'fourHour': 1000, 'weekly': null},
  'usage': <String, dynamic>{'fourHour': 120, 'weekly': 4000},
  'remaining': <String, dynamic>{'fourHour': 880, 'weekly': null},
  'reached': <String, dynamic>{'fourHour': false, 'weekly': false},
  'nextDecreaseAt': <String, dynamic>{},
};

/// One realistic answer per admin endpoint, long values included, so every
/// area lays out with data rather than with its empty state.
http.Response _everything(http.Request request) {
  final path = request.url.path.replaceFirst('/api/v1/admin', '');
  if (path.startsWith('/users/') && path.endsWith('/usage-limits')) {
    return _json(<String, dynamic>{
      'username': 'a-rather-long-account-name',
      'aiLimit4h': null,
      'aiLimitWeekly': 0,
      'transcriptionLimit4h': 3600,
      'transcriptionLimitWeekly': null,
      'usage': <String, dynamic>{'ai': _usage, 'transcription': _usage},
    });
  }
  return switch (path) {
    '/stats' => _json(<String, dynamic>{
      ..._stats,
      'oldestQueuedAt': '2026-09-25T08:00:00.000Z',
      'temporaryAudioBytes': 52428800,
      'workers': <Map<String, dynamic>>[
        <String, dynamic>{
          'host': 'worker-host-with-a-long-name.internal.example',
          'model_state': 'ready',
          'heartbeat_at': '2026-09-25T09:00:00.000Z',
        },
      ],
      'processing': <Map<String, dynamic>>[
        <String, dynamic>{
          'metric': 'transcription_realtime_factor',
          'average': 0.4123,
          'maximum': 1.9,
          'unit': 'ratio',
        },
      ],
    }),
    '/users' => _json(<String, dynamic>{
      'users': <Map<String, dynamic>>[
        for (var index = 0; index < 10; index += 1)
          <String, dynamic>{
            'id': 'user-$index',
            'username': index == 0 ? 'owner' : 'person-with-a-long-name-$index',
            'email': 'someone.with.a.long.address.$index@example.com',
            'role': index == 0 ? 'admin' : 'user',
            'disabled_at': index == 3 ? '2026-09-01T00:00:00.000Z' : null,
            'created_at': '2026-08-01T00:00:00.000Z',
            'last_login_at': index.isEven ? '2026-09-24T00:00:00.000Z' : null,
            'device_count': index,
            'recording_count': index * 7,
          },
      ],
    }),
    '/config/usage-limits' => _json(<String, dynamic>{
      'limits': <String, dynamic>{
        'aiTokens4h': 2500000,
        'aiTokensWeekly': 10000000,
        'transcriptionSeconds4h': 0,
        'transcriptionSecondsWeekly': 0,
      },
    }),
    '/jobs' => _json(<String, dynamic>{
      'jobs': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'job-1',
          'type': 'transcribe_chunk',
          'status': 'failed',
          'attempts': 5,
          'max_attempts': 5,
          'last_error_code': 'TRANSCRIPTION_PROVIDER_UNREACHABLE',
          'last_error_message':
              'The transcription service at http://10.0.0.5:9000/v1 did not answer within 1800 seconds.',
          'created_at': '2026-09-25T07:00:00.000Z',
        },
        <String, dynamic>{
          'id': 'job-2',
          'type': 'consolidate_memories',
          'status': 'queued',
          'attempts': 0,
          'max_attempts': 5,
          'created_at': '2026-09-25T07:05:00.000Z',
        },
      ],
    }),
    '/ai-requests' => _json(<String, dynamic>{
      'requests': <Map<String, dynamic>>[
        <String, dynamic>{
          'purpose': 'memory_consolidation',
          'state': 'failed',
          'model':
              'a-very-long-model-identifier-with-a-quantisation-suffix-q4_k_m',
          'prompt_tokens': 12000,
          'completion_tokens': 800,
          'error_code': 'LLM_OUTPUT_TRUNCATED',
          'sent_at': '2026-09-25T07:10:00.000Z',
        },
      ],
    }),
    '/audit' => _json(<String, dynamic>{
      'entries': <Map<String, dynamic>>[
        <String, dynamic>{
          'actor_type': 'admin',
          'actor_username': 'owner',
          'affected_username': 'person-with-a-long-name-3',
          'action': 'user_disabled',
          'resource_type': null,
          'resource_id': null,
          'created_at': '2026-09-25T07:20:00.000Z',
        },
        <String, dynamic>{
          'actor_type': 'system',
          'action': 'admin_granted',
          'affected_username': 'owner',
          'created_at': '2026-09-25T07:21:00.000Z',
        },
      ],
    }),
    '/backups' => _json(<String, dynamic>{
      ..._backups,
      'history': <Map<String, dynamic>>[
        <String, dynamic>{
          'started_at': '2026-09-24T02:00:00.000Z',
          'trigger_kind': 'scheduled',
          'state': 'failed',
          'error_code': 'BACKUP_DESTINATION_UNREACHABLE',
          'error_message': 'connect ECONNREFUSED 10.0.0.9:443',
          'bytes': 0,
        },
        <String, dynamic>{
          'started_at': '2026-09-23T02:00:00.000Z',
          'trigger_kind': 'manual',
          'state': 'succeeded',
          'bytes': 73400320,
          'artifact_key': 'neorecall-20260923T020000Z-a1b2c3.nrbak',
          'pruned_at': '2026-09-25T02:00:00.000Z',
        },
      ],
    }),
    '/processing-settings' => _json(<String, dynamic>{
      'settings': <String, dynamic>{
        'voiceMatchThreshold': 0.72,
        'speakerMinimumTurnMs': 1200,
        'audioPreprocessEnabled': true,
        'conversationHardGapMs': 300000,
        'memoryDedupeEnabled': false,
        'aSettingThisBuildDoesNotKnow': 3,
      },
    }),
    '/provider-settings' => _json(<String, dynamic>{
      'settings': <String, dynamic>{
        'transcription': <String, dynamic>{
          'provider': 'openai-compatible',
          'label': 'Custom OpenAI-compatible',
          'model': 'whisper-large-v3',
          'baseUrl': 'http://10.0.0.5:9000/v1',
          'apiKeyConfigured': true,
          'apiKeySource': 'environment',
          'language': 'de',
          'responseFormat': 'verbose_json',
          'sources': <String, dynamic>{'provider': 'environment'},
        },
        'llm': <String, dynamic>{
          'provider': 'openai',
          'label': 'OpenAI',
          'model': 'gpt-4o-mini',
          'baseUrl': 'https://api.openai.com/v1',
          'apiKeyConfigured': true,
          'apiKeySource': 'admin',
          'extraBody': <String, dynamic>{
            'chat_template_kwargs': <String, dynamic>{'enable_thinking': false},
          },
          'sources': <String, dynamic>{'provider': 'admin'},
        },
        'catalogs': <String, dynamic>{
          'transcription': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'openai-compatible',
              'label': 'Custom OpenAI-compatible',
              'protocol': 'openai',
              'defaultBaseUrl': null,
              'apiKeyRequired': false,
              'modelOptional': true,
            },
          ],
          'llm': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'openai',
              'label': 'OpenAI',
              'protocol': 'openai',
              'defaultBaseUrl': 'https://api.openai.com/v1',
              'apiKeyRequired': true,
              'modelOptional': false,
            },
          ],
        },
      },
    }),
    _ => _json(<String, dynamic>{}, 404),
  };
}

NeoRecallController _controller(
  Future<http.Response> Function(http.Request) handler,
) => NeoRecallController(
  api: NeoRecallApiClient(
    baseUrl: 'http://server.test',
    token: 'session-token',
    client: MockClient(handler),
  ),
);

Future<void> _pumpAdmin(
  WidgetTester tester,
  NeoRecallController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      theme: buildNeoRecallTheme(Brightness.light),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => AdminScreen(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Admin is offered to admin accounts only', () {
    final controller = NeoRecallController();
    addTearDown(controller.dispose);
    bool offersAdmin() => neoRecallNavigationGroupsFor(
      controller,
    ).any((group) => group.destinations.any((d) => d.page == RecallPage.admin));

    expect(offersAdmin(), isFalse);
    expect(neoRecallTabDestinationsFor(controller), hasLength(4));

    controller.isAdmin = true;
    expect(offersAdmin(), isTrue);
    expect(neoRecallTabDestinationsFor(controller), hasLength(5));
    controller.page = RecallPage.admin;
    expect(neoRecallTabIndex(controller), 4);
  });

  test(
    'a server this app just installed opens Admin › Providers for its first admin',
    () {
      final controller = NeoRecallController();
      addTearDown(controller.dispose);

      controller
        ..openProvidersAfterSignIn()
        ..adoptSignedInRole('admin');
      expect(controller.isAdmin, isTrue);
      expect(controller.page, RecallPage.admin);
      expect(controller.adminArea, AdminArea.providers);

      // Only for that one sign-in, and never for an account that is not admin.
      controller
        ..page = RecallPage.record
        ..adoptSignedInRole('admin');
      expect(controller.page, RecallPage.record);
      controller
        ..openProvidersAfterSignIn()
        ..adoptSignedInRole('user');
      expect(controller.page, RecallPage.record);
      expect(controller.isAdmin, isFalse);
    },
  );

  test('the foreground refresh follows a role the operator changed', () async {
    var role = 'admin';
    final controller = _controller((request) async {
      if (request.url.path == '/api/v1/auth/me') {
        return _json(<String, dynamic>{
          'user': <String, dynamic>{'id': 'account', 'role': role},
        });
      }
      return _json(<String, dynamic>{}, 404);
    })..accountId = 'account';
    addTearDown(controller.dispose);

    await controller.refreshAll(silent: true);
    expect(controller.isAdmin, isTrue);

    controller.page = RecallPage.admin;
    role = 'user';
    await controller.refreshAll(silent: true);
    expect(controller.isAdmin, isFalse);
    expect(controller.page, RecallPage.settings);
    // refreshAll leaves the usage refresh running; let it land before the
    // controller is disposed.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('an account that loses admin leaves the Admin page', () {
    final controller = NeoRecallController()
      ..isAdmin = true
      ..page = RecallPage.admin;
    addTearDown(controller.dispose);

    controller.adminAccessRevoked();

    expect(controller.isAdmin, isFalse);
    expect(controller.page, RecallPage.settings);
  });

  testWidgets('the overview loads, and a search result opens its card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final paths = <String>[];
    final controller = _controller((request) async {
      expect(request.headers['Authorization'], 'Bearer session-token');
      paths.add(request.url.path);
      return switch (request.url.path) {
        '/api/v1/admin/stats' => _json(_stats),
        '/api/v1/admin/backups' => _json(_backups),
        _ => _json(<String, dynamic>{}, 404),
      };
    })..isAdmin = true;
    addTearDown(controller.dispose);

    await _pumpAdmin(tester, controller);

    expect(find.text('9.9.9'), findsOneWidget);
    expect(find.text('Queued work'), findsOneWidget);
    // Two failed jobs: counted on the overview and flagged in the navigation.
    expect(find.text('Failed jobs'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Jobs'),
          matching: find.byType(InkWell),
        ),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).first, 'backup');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();

    expect(controller.adminArea, AdminArea.backups);
    expect(paths, contains('/api/v1/admin/backups'));
    expect(find.text('Every 24 hours'), findsOneWidget);

    // The card the result pointed at is outlined for a moment, then not.
    BoxDecoration outline() =>
        tester
                .widget<AnimatedContainer>(
                  find
                      .ancestor(
                        of: find.text('BACKUPS'),
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    final lit = outline().border! as Border;
    expect(lit.top.color, isNot(Colors.transparent));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect((outline().border! as Border).top.color, Colors.transparent);
  });

  testWidgets('a refusal for lost admin rights takes the page away', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller =
        _controller(
            (request) async => _json(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 'ADMIN_REQUIRED',
                'message': 'Admin access is required.',
              },
            }, 403),
          )
          ..isAdmin = true
          ..page = RecallPage.admin;
    addTearDown(controller.dispose);

    await _pumpAdmin(tester, controller);

    expect(controller.isAdmin, isFalse);
    expect(controller.page, RecallPage.settings);
  });

  testWidgets(
    'jobs open on failures, and the filter asks the server for the rest',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final asked = <String?>[];
      final controller =
          _controller((request) async {
              if (request.url.path == '/api/v1/admin/jobs') {
                asked.add(request.url.queryParameters['status']);
                return _json(<String, dynamic>{
                  'jobs': <Map<String, dynamic>>[],
                });
              }
              return _everything(request);
            })
            ..isAdmin = true
            ..adminArea = AdminArea.jobs;
      addTearDown(controller.dispose);

      await _pumpAdmin(tester, controller);
      expect(asked, <String?>['failed']);
      expect(find.text('No failed jobs.'), findsOneWidget);

      await tester.tap(find.text('Waiting'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(asked, <String?>['failed', 'queued', null]);
      expect(find.text('No jobs yet.'), findsOneWidget);
    },
  );

  for (final size in <Size>[const Size(390, 844), const Size(1180, 780)]) {
    testWidgets('every Admin area lays out at ${size.width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _controller((request) async => _everything(request))
        ..isAdmin = true;
      addTearDown(controller.dispose);

      for (final area in AdminArea.values) {
        controller.adminArea = area;
        await _pumpAdmin(tester, controller);
        expect(
          tester.takeException(),
          isNull,
          reason: '${area.name} overflowed or threw at ${size.width}px',
        );
      }

      // The per-account limits dialog, with every kind of value in it.
      controller.adminArea = AdminArea.users;
      await _pumpAdmin(tester, controller);
      await tester.ensureVisible(find.text('Limits').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Limits').first);
      await tester.pumpAndSettle();
      expect(find.text('Limits for owner'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
