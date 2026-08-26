/* NeoRecall landing — Control Surface interactions */
(function () {
  'use strict';

  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const nav = document.querySelector('[data-nav]');
  const toggle = document.querySelector('[data-nav-toggle]');
  const mobileMenu = document.querySelector('[data-mobile-menu]');

  /* ---------- nav ---------- */
  const onScrollNav = () => {
    if (!nav) return;
    nav.classList.toggle('scrolled', window.scrollY > 10);
  };
  window.addEventListener('scroll', onScrollNav, { passive: true });
  onScrollNav();

  if (toggle && nav) {
    toggle.addEventListener('click', () => {
      const open = nav.classList.toggle('open');
      toggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    });
    mobileMenu?.querySelectorAll('a').forEach((link) => {
      link.addEventListener('click', () => {
        nav.classList.remove('open');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.setAttribute('aria-label', 'Open menu');
      });
    });
  }

  /* ---------- scroll reveals ---------- */
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting) {
        e.target.classList.add('in');
        io.unobserve(e.target);
      }
    });
  }, { threshold: 0.15, rootMargin: '0px 0px -5% 0px' });

  document.querySelectorAll('.reveal, [data-stagger]').forEach((el) => io.observe(el));

  // stagger indices + a tiny random tilt per channel chip (human touch)
  document.querySelectorAll('[data-stagger]').forEach((grid) => {
    grid.querySelectorAll('.channel-chip').forEach((chip, i) => {
      chip.style.setProperty('--i', i);
      chip.style.setProperty('--r', ((i % 5) - 2) * 0.8);
    });
  });

  /* ---------- scroll progress ---------- */
  const bar = document.createElement('div');
  bar.className = 'scroll-progress';
  bar.setAttribute('aria-hidden', 'true');
  document.body.appendChild(bar);
  const onProgress = () => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    bar.style.width = (max > 0 ? (window.scrollY / max) * 100 : 0) + '%';
  };
  window.addEventListener('scroll', onProgress, { passive: true });
  onProgress();

  /* ---------- hide sign-in on static GitHub Pages hosts ---------- */
  if (location.hostname.includes('github.io')) {
    document.querySelectorAll('a.signin').forEach((a) => { a.style.display = 'none'; });
  }

  /* ---------- pointer tilt on framed surfaces ---------- */
  if (!reduced && matchMedia('(hover: hover) and (pointer: fine)').matches) {
    document.querySelectorAll('[data-tilt]').forEach((el) => {
      const base = {
        ty: parseFloat(getComputedStyle(el).getPropertyValue('--ty')) || 0,
        tx: parseFloat(getComputedStyle(el).getPropertyValue('--tx')) || 0,
      };
      el.addEventListener('pointermove', (ev) => {
        const r = el.getBoundingClientRect();
        const px = (ev.clientX - r.left) / r.width - 0.5;
        const py = (ev.clientY - r.top) / r.height - 0.5;
        el.style.setProperty('--ty', (base.ty + px * 5).toFixed(2));
        el.style.setProperty('--tx', (base.tx - py * 4).toFixed(2));
      });
      el.addEventListener('pointerleave', () => {
        el.style.setProperty('--ty', base.ty);
        el.style.setProperty('--tx', base.tx);
      });
    });
  }

  /* ============================================================
     Flutter Search replica — query, answer, citations, result card
     ============================================================ */
  const demo = document.querySelector('[data-chat-demo]');
  if (demo) {
    const results = demo.querySelector('[data-demo-thread]');
    const input = demo.querySelector('[data-demo-input]');
    const status = demo.querySelector('[data-demo-status]');
    const askButton = demo.querySelector('.fa-ask');
    const chips = document.querySelectorAll('.demo-chip');

    const scenarios = [
      {
        query: 'What did I promise in the enclosure meeting?',
        answer: 'You promised to send the revised enclosure dimensions after lunch. The team had just chosen the smaller enclosure.',
        citation: 'memory · 10:14',
        kind: 'memory',
        score: '0.923',
        title: 'Hardware planning',
        body: 'The smaller enclosure was selected. Revised dimensions will be sent after lunch and reviewed before the prototype order.',
      },
      {
        query: 'Who recommended the quiet café near the station?',
        answer: 'Maya recommended Café Morgen. She said the back room stays quiet enough for a client call.',
        citation: 'transcript · Tuesday 12:36',
        kind: 'transcript',
        score: '0.901',
        title: 'Lunch with Maya',
        body: 'Café Morgen near the station has a quiet back room. Maya recommended it for conversations that need privacy.',
      },
      {
        query: 'Why did we move the release to Thursday?',
        answer: 'The migration rehearsal exposed a rollback gap. The decision was to fix it Wednesday and release Thursday morning.',
        citation: 'memory · 15:47',
        kind: 'memory',
        score: '0.887',
        title: 'Release review',
        body: 'The release moved to Thursday so the rollback path could be corrected and rehearsed before shipping.',
      },
    ];

    let timers = [];
    let running = 0;

    const later = (fn, ms) => { timers.push(setTimeout(fn, reduced ? 0 : ms)); };
    const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };

    const setStatus = (busy) => {
      status.textContent = busy ? 'searching' : 'ready';
      askButton.classList.toggle('armed', busy);
    };

    const setQuery = (value, placeholder = false) => {
      input.textContent = '';
      const text = document.createElement('span');
      text.className = placeholder ? 'fa-placeholder' : 'fa-query-text';
      text.textContent = value;
      input.appendChild(text);
      const caret = document.createElement('span');
      caret.className = 'caret';
      caret.setAttribute('aria-hidden', 'true');
      input.appendChild(caret);
    };

    const renderResult = (scenario) => {
      results.innerHTML =
        '<div class="fa-answer">' +
          '<span>ANSWER</span>' +
          '<p>' + scenario.answer + '</p>' +
          '<div class="fa-citations"><i>↗ ' + scenario.citation + '</i></div>' +
        '</div>' +
        '<div class="fa-result-card">' +
          '<div class="fa-result-meta"><span class="fa-kind">' + scenario.kind + '</span><span class="fa-score">' + scenario.score + '</span></div>' +
          '<strong>' + scenario.title + '</strong>' +
          '<p>' + scenario.body + '</p>' +
        '</div>';
    };

    const play = (index) => {
      clearTimers();
      const scenario = scenarios[index];
      const run = ++running;
      const alive = () => run === running;

      results.innerHTML = '';
      setQuery('Try a name, topic, or event…', true);
      setStatus(false);

      later(() => {
        if (!alive()) return;
        if (reduced) {
          setQuery(scenario.query);
          search();
          return;
        }

        let cursor = 0;
        const type = () => {
          if (!alive()) return;
          cursor += 1;
          setQuery(scenario.query.slice(0, cursor));
          if (cursor < scenario.query.length) {
            timers.push(setTimeout(type, 24 + Math.random() * 36));
          } else {
            askButton.classList.add('armed');
            later(search, 380);
          }
        };
        type();
      }, 650);

      const search = () => {
        if (!alive()) return;
        setStatus(true);
        results.innerHTML = '<div class="fa-loading" aria-label="Searching memories"><span><i></i><i></i><i></i></span></div>';
        later(() => {
          if (!alive()) return;
          renderResult(scenario);
          setStatus(false);
          later(() => { if (alive()) select((index + 1) % scenarios.length); }, 7000);
        }, 1450);
      };
    };

    const select = (index) => {
      chips.forEach((chip) => {
        chip.classList.toggle('is-active', Number(chip.dataset.scenario) === index);
      });
      play(index);
    };

    chips.forEach((chip) => {
      chip.addEventListener('click', () => select(Number(chip.dataset.scenario)));
    });

    const demoIo = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        demoIo.disconnect();
        select(0);
      }
    }, { threshold: 0.4 });
    demoIo.observe(demo);
  }

  /* ============================================================
     Scrollytelling — steps drive the sticky stage
     ============================================================ */
  const story = document.querySelector('[data-story]');
  if (story) {
    const steps = story.querySelectorAll('[data-step]');
    const panels = story.querySelectorAll('[data-panel]');

    const activate = (idx) => {
      steps.forEach((s) => s.classList.toggle('is-active', Number(s.dataset.step) === idx));
      panels.forEach((p) => p.classList.toggle('is-active', Number(p.dataset.panel) === idx));
    };

    const stepIo = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) activate(Number(e.target.dataset.step));
      });
    }, { threshold: 0.55 });
    steps.forEach((s) => stepIo.observe(s));
    activate(0);

    /* ---- run-panel loop: steps complete one after another ---- */
    const runSteps = story.querySelectorAll('[data-run-steps] .run-step');
    if (runSteps.length && !reduced) {
      let cursor = 0;
      const advance = () => {
        runSteps.forEach((s, i) => {
          s.classList.toggle('done', i < cursor);
          s.classList.toggle('doing', i === cursor);
        });
        cursor++;
        if (cursor > runSteps.length) cursor = 0;
      };
      advance();
      setInterval(advance, 1900);
    } else {
      runSteps.forEach((s) => s.classList.add('done'));
    }

    /* ---- memory graph: build, drift, hover-highlight, cycle facts ---- */
    const graph = story.querySelector('[data-mem-graph]');
    if (graph) {
      const nodes = [
        { id: 'neorecall', label: 'NeoRecall', x: 230, y: 128, r: 20 },
        { id: 'maya', label: 'Maya', x: 118, y: 60, r: 15 },
        { id: 'flutter', label: 'Flutter', x: 66, y: 168, r: 14 },
        { id: 'mac', label: 'Mac mini', x: 190, y: 205, r: 15 },
        { id: 'prefers', label: 'Prefers', x: 330, y: 52, r: 13 },
        { id: 'primary', label: 'Primary', x: 392, y: 150, r: 16 },
        { id: 'when', label: 'Evenings', x: 320, y: 210, r: 12 },
      ];
      const links = [
        ['neorecall', 'maya'], ['neorecall', 'flutter'], ['neorecall', 'mac'],
        ['neorecall', 'primary'], ['maya', 'prefers'], ['primary', 'when'],
        ['mac', 'flutter'], ['prefers', 'primary'],
      ];
      const facts = {
        neorecall: 'The smaller enclosure was chosen; revised dimensions are due after lunch.',
        maya: 'Maya recommended Café Morgen because its back room stays quiet enough for client calls.',
        flutter: 'NeoRecall records from a Flutter client and processes speech on the self-hosted server.',
        mac: 'The local server holds the searchable transcript and memory database.',
        prefers: 'A preference for quiet meeting spaces appears across several conversations.',
        primary: 'The hardware planning memory connects the enclosure decision to a promised follow-up.',
        when: 'The revised dimensions are expected after lunch.',
      };

      const ns = 'http://www.w3.org/2000/svg';
      const linkGroup = graph.querySelector('.mem-links');
      const nodeGroup = graph.querySelector('.mem-nodes');
      const factText = story.querySelector('[data-mem-fact-text]');
      const byId = {};
      nodes.forEach((n) => { byId[n.id] = n; });

      const lineEls = links.map(([a, b]) => {
        const l = document.createElementNS(ns, 'line');
        l.dataset.a = a;
        l.dataset.b = b;
        linkGroup.appendChild(l);
        return l;
      });

      const nodeEls = nodes.map((n) => {
        const g = document.createElementNS(ns, 'g');
        g.setAttribute('class', 'mem-node');
        g.dataset.id = n.id;
        const halo = document.createElementNS(ns, 'circle');
        halo.setAttribute('class', 'halo');
        halo.setAttribute('r', n.r);
        const core = document.createElementNS(ns, 'circle');
        core.setAttribute('class', 'core');
        core.setAttribute('r', Math.max(3, n.r * 0.28));
        const label = document.createElementNS(ns, 'text');
        label.setAttribute('dy', n.r + 13);
        label.textContent = n.label;
        g.append(halo, core, label);
        nodeGroup.appendChild(g);
        return g;
      });

      const highlight = (id) => {
        nodeEls.forEach((g) => {
          const active = !id || g.dataset.id === id ||
            links.some(([a, b]) => (a === id && b === g.dataset.id) || (b === id && a === g.dataset.id));
          g.classList.toggle('lit', Boolean(id) && active);
        });
        lineEls.forEach((l) => {
          l.classList.toggle('lit', Boolean(id) && (l.dataset.a === id || l.dataset.b === id));
        });
        if (id && facts[id] && factText) factText.textContent = facts[id];
      };

      nodeEls.forEach((g) => {
        g.addEventListener('pointerenter', () => highlight(g.dataset.id));
        g.addEventListener('click', () => highlight(g.dataset.id));
      });
      graph.addEventListener('pointerleave', () => highlight(null));

      // gentle autonomous drift + a slow tour through the facts
      let t = 0;
      let tourIdx = 0;
      const drift = () => {
        t += 0.008;
        nodes.forEach((n, i) => {
          n.dx = Math.sin(t * (0.7 + i * 0.13) + i * 2.1) * 6;
          n.dy = Math.cos(t * (0.6 + i * 0.11) + i * 1.3) * 5;
        });
        nodeEls.forEach((g, i) => {
          const n = nodes[i];
          g.setAttribute('transform', 'translate(' + (n.x + n.dx) + ',' + (n.y + n.dy) + ')');
        });
        lineEls.forEach((l) => {
          const a = byId[l.dataset.a];
          const b = byId[l.dataset.b];
          l.setAttribute('x1', a.x + a.dx); l.setAttribute('y1', a.y + a.dy);
          l.setAttribute('x2', b.x + b.dx); l.setAttribute('y2', b.y + b.dy);
        });
        requestAnimationFrame(drift);
      };

      if (reduced) {
        nodes.forEach((n) => { n.dx = 0; n.dy = 0; });
        nodeEls.forEach((g, i) => {
          g.setAttribute('transform', 'translate(' + nodes[i].x + ',' + nodes[i].y + ')');
        });
        lineEls.forEach((l) => {
          const a = byId[l.dataset.a];
          const b = byId[l.dataset.b];
          l.setAttribute('x1', a.x); l.setAttribute('y1', a.y);
          l.setAttribute('x2', b.x); l.setAttribute('y2', b.y);
        });
      } else {
        nodes.forEach((n) => { n.dx = 0; n.dy = 0; });
        requestAnimationFrame(drift);
        setInterval(() => {
          if (!graph.matches(':hover')) {
            highlight(nodes[tourIdx % nodes.length].id);
            tourIdx++;
          }
        }, 3400);
      }
    }
  }

  /* ============================================================
     Terminal — type the install command when it scrolls into view
     ============================================================ */
  const term = document.querySelector('[data-term]');
  if (term) {
    const cmdEl = term.querySelector('[data-term-cmd]');
    const outLines = term.querySelectorAll('[data-term-out] > div');
    const cmd = cmdEl.getAttribute('data-term-cmd');

    const runTerm = () => {
      if (reduced) {
        cmdEl.textContent = cmd;
        outLines.forEach((l) => l.classList.add('show'));
        return;
      }
      let i = 0;
      const type = () => {
        i++;
        cmdEl.textContent = cmd.slice(0, i);
        if (i < cmd.length) {
          setTimeout(type, 34 + Math.random() * 40);
        } else {
          outLines.forEach((l, j) => {
            setTimeout(() => l.classList.add('show'), 500 + j * 380);
          });
        }
      };
      setTimeout(type, 400);
    };

    const termIo = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        termIo.disconnect();
        runTerm();
      }
    }, { threshold: 0.5 });
    termIo.observe(term);
  }
})();
