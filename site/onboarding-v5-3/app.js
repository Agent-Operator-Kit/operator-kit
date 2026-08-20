/*
 * Operator onboarding install flow — test harness behaviour.
 *
 * Everything here is local DOM state. No network calls, no storage, no host API.
 * Two entries (`github`, `plugin`) converge on one Codex-owned install screen;
 * the flow stops honestly at the boundary of this implementation slice.
 */

(() => {
  'use strict';

  const root = document.getElementById('ok-window');
  if (!root) return;

  const turns = new Map(
    [...root.querySelectorAll('[data-turn]')].map((el) => [el.dataset.turn, el])
  );
  const replyGroups = new Map(
    [...root.querySelectorAll('[data-replies]')].map((el) => [el.dataset.replies, el])
  );
  const composePanels = new Map(
    [...root.querySelectorAll('[data-compose]')].map((el) => [el.dataset.compose, el])
  );
  const cardFeet = new Map(
    [...root.querySelectorAll('[data-card-foot]')].map((el) => [el.dataset.cardFoot, el])
  );

  const stages = new Map(
    [...root.querySelectorAll('.ok-stage')].map((el) => [el.dataset.stage, el])
  );
  const operatorBand = root.querySelector('#ok-band-operator');
  const bandNote = root.querySelector('[data-band-note]');
  const chip = root.querySelector('#ok-chip');
  const chipText = root.querySelector('[data-chip-text]');
  const emptyState = root.querySelector('#ok-empty');
  const thread = root.querySelector('#ok-thread');
  const commandline = root.querySelector('#ok-commandline');
  const composerHeading = root.querySelector('[data-composer-heading]');
  const composerOwner = root.querySelector('[data-composer-owner]');
  const sourceNote = root.querySelector('[data-source-note]');
  const boundary = root.querySelector('[data-boundary]');
  const boundaryText = root.querySelector('[data-boundary-text]');
  const live = root.querySelector('#ok-live');
  const entryButtons = [...document.querySelectorAll('[data-entry]')];

  const ENTRIES = ['github', 'plugin'];
  const SHAREABLE_STEPS = ['entry', 'screen', 'installed', 'next'];

  const SCREEN_HEAD = {
    github: ['request-echo', 'install-screen'],
    plugin: ['entry-marker', 'install-screen']
  };
  const INSTALLED_TAIL = ['receipt', 'handoff', 'operator-hello'];
  const NEXT_TAIL = ['user-check', 'next-slice'];

  const SOURCE_NOTE = {
    github: 'Matches the repository in the instruction you sent.',
    plugin: 'Listed by Codex for this plugin. The same repository, resolved without a paste.'
  };

  const STEPS = {
    entry: {
      turns: () => [],
      replies: () => (entry === 'github' ? 'compose-github' : 'compose-plugin'),
      commandline: () => entry === 'github',
      compose: () => entry,
      stages: { install: 'current', check: 'locked' },
      installed: false,
      cardFoot: 'actions',
      bandNote: 'Not installed yet',
      chip: 'Operator not installed',
      chipTone: null,
      composerHeading: () => (entry === 'github' ? 'Message' : 'Next step'),
      owner: 'codex',
      ownerText: 'Codex',
      boundary: () =>
        'Operator is not installed, so nothing of it can read, message, or change anything yet.',
      boundaryTone: null,
      live: () =>
        entry === 'github'
          ? 'Nothing installed. Sending the instruction only opens the install screen.'
          : 'Nothing installed. The install screen can be opened again.'
    },

    screen: {
      turns: () => SCREEN_HEAD[entry],
      replies: () => 'screen',
      commandline: () => false,
      compose: () => null,
      stages: { install: 'current', check: 'locked' },
      installed: false,
      cardFoot: 'actions',
      bandNote: 'Not installed yet',
      chip: 'Operator not installed',
      chipTone: null,
      composerHeading: () => 'Install screen',
      owner: 'codex',
      ownerText: 'Codex',
      boundary: () =>
        'Nothing is installed yet. The source has been resolved and Codex is waiting for you to choose.',
      boundaryTone: null,
      live: () =>
        entry === 'github'
          ? 'Codex resolved the GitHub source and opened its install screen. Nothing is installed yet.'
          : 'Codex opened its install screen from the plugin entry. Nothing is installed yet.'
    },

    installing: {
      turns: () => [...SCREEN_HEAD[entry], 'installing'],
      replies: () => 'installing',
      commandline: () => false,
      compose: () => null,
      stages: { install: 'current', check: 'locked' },
      installed: false,
      cardFoot: 'installing',
      bandNote: 'Not installed yet',
      chip: 'Installing Operator',
      chipTone: null,
      composerHeading: () => 'Install screen',
      owner: 'codex',
      ownerText: 'Codex',
      boundary: () =>
        'Installing adds Operator to Codex only. Nothing in this repository is read or written.',
      boundaryTone: 'pending',
      live: () => 'Installing Operator in Codex. The repository is not being read.'
    },

    installed: {
      turns: () => [...SCREEN_HEAD[entry], ...INSTALLED_TAIL],
      replies: () => 'installed',
      commandline: () => false,
      compose: () => null,
      stages: { install: 'done', check: 'current' },
      installed: true,
      cardFoot: 'resolved',
      bandNote: 'Installed — this project is still untouched',
      chip: 'Installed in Codex · repository unchanged',
      chipTone: 'installed',
      composerHeading: () => 'Your reply',
      owner: 'operator',
      ownerText: 'Operator',
      boundary: () =>
        'Operator was added to Codex from the resolved source. It has still not read this repository.',
      boundaryTone: null,
      live: () =>
        'Operator installed from github.com/Agent-Operator-Kit/operator-kit. Repository unchanged; Operator can now respond.'
    },

    next: {
      turns: () => [...SCREEN_HEAD[entry], ...INSTALLED_TAIL, ...NEXT_TAIL],
      replies: () => 'next',
      commandline: () => false,
      compose: () => null,
      stages: { install: 'done', check: 'current' },
      installed: true,
      cardFoot: 'resolved',
      bandNote: 'Not implemented in this slice',
      chip: 'Installed in Codex · repository unchanged',
      chipTone: 'installed',
      composerHeading: () => 'Your reply',
      owner: 'operator',
      ownerText: 'Operator',
      boundary: () =>
        'The project check is not implemented in this harness. Nothing was read, run, or written.',
      boundaryTone: 'pending',
      live: () =>
        'Next implementation slice: the read-only project check is not built yet. Nothing was read and nothing ran.'
    }
  };

  const ACTION_STEP = {
    send: 'screen',
    open: 'screen',
    cancel: 'entry',
    install: 'installing',
    check: 'next',
    restart: null // resolved from the current entry
  };

  const REDUCED_MOTION =
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const INSTALL_MS = REDUCED_MOTION ? 300 : 750;

  let entry = 'github';
  let step = 'entry';
  let installTimer = null;

  const defaultStep = () => (entry === 'plugin' ? 'screen' : 'entry');

  function clearInstallTimer() {
    if (installTimer !== null) {
      window.clearTimeout(installTimer);
      installTimer = null;
    }
  }

  function syncUrl() {
    if (step === 'installing') return; // transient: never shareable
    try {
      const url = new URL(window.location.href);
      url.searchParams.set('entry', entry);
      url.searchParams.set('step', step);
      window.history.replaceState(null, '', url);
    } catch (error) {
      /* file:// or a browser refusing replaceState — the harness still works in-page */
    }
  }

  function render() {
    const state = STEPS[step];
    const visible = state.turns();
    const composePanel = state.compose();

    turns.forEach((el, key) => { el.hidden = !visible.includes(key); });
    replyGroups.forEach((el, key) => { el.hidden = key !== state.replies(); });
    composePanels.forEach((el, key) => { el.hidden = key !== composePanel; });
    cardFeet.forEach((el, key) => { el.hidden = key !== state.cardFoot; });

    emptyState.hidden = composePanel === null;
    commandline.hidden = !state.commandline();
    thread.dataset.empty = visible.length ? 'false' : 'true';

    stages.forEach((el, key) => { el.dataset.state = state.stages[key]; });
    operatorBand.dataset.locked = state.installed ? 'false' : 'true';
    bandNote.textContent = state.bandNote;

    chipText.textContent = state.chip;
    if (state.chipTone) {
      chip.dataset.tone = state.chipTone;
    } else {
      delete chip.dataset.tone;
    }

    composerHeading.textContent = state.composerHeading();
    composerOwner.dataset.owner = state.owner;
    composerOwner.textContent = state.ownerText;

    sourceNote.textContent = SOURCE_NOTE[entry];

    boundaryText.textContent = state.boundary();
    if (state.boundaryTone) {
      boundary.dataset.tone = state.boundaryTone;
    } else {
      delete boundary.dataset.tone;
    }

    live.textContent = state.live();

    entryButtons.forEach((button) => {
      button.setAttribute('aria-pressed', String(button.dataset.entry === entry));
    });

    if (visible.length) {
      turns.get(visible[visible.length - 1]).scrollIntoView({ block: 'nearest' });
    }
  }

  // Move focus to the action the user is expected to reach next, so a keyboard
  // user is not dropped on <body> when the control they pressed disappears.
  function focusPrimary() {
    // On the install screen the decision lives on the card, not in the composer.
    const owner =
      step === 'screen'
        ? cardFeet.get('actions')
        : replyGroups.get(STEPS[step].replies());
    const target = owner && !owner.hidden && owner.querySelector('button');
    if (target) target.focus();
  }

  function goTo(next, { focus = true } = {}) {
    clearInstallTimer();
    step = STEPS[next] ? next : defaultStep();
    syncUrl();
    render();
    if (focus) focusPrimary();

    if (step === 'installing') {
      installTimer = window.setTimeout(() => {
        installTimer = null;
        goTo('installed');
      }, INSTALL_MS);
    }
  }

  function setEntry(next, { resetStep = true, focus = false } = {}) {
    entry = ENTRIES.includes(next) ? next : 'github';
    if (resetStep) {
      goTo(defaultStep(), { focus });
    } else {
      syncUrl();
      render();
    }
  }

  entryButtons.forEach((button) => {
    button.addEventListener('click', () => setEntry(button.dataset.entry, { focus: true }));
  });

  root.addEventListener('click', (event) => {
    const button = event.target.closest('[data-action]');
    if (!button || !root.contains(button)) return;
    const action = button.dataset.action;
    if (!(action in ACTION_STEP)) return;
    goTo(ACTION_STEP[action] || defaultStep());
  });

  // Copy the pasted instruction, degrading honestly where the Clipboard API is
  // unavailable or refused (file://, insecure origins, denied permission).
  const copyButton = root.querySelector('#ok-copy');
  const copyLabel = root.querySelector('[data-copy-text]');
  const instruction = root.querySelector('#ok-cmd').textContent.trim();
  let copyReset = null;

  copyButton.addEventListener('click', async () => {
    let copied = false;
    try {
      await navigator.clipboard.writeText(instruction);
      copied = true;
    } catch (error) {
      copied = false;
    }
    copyLabel.textContent = copied ? 'Copied' : 'Select to copy';
    live.textContent = copied
      ? 'Copied the install instruction to the clipboard.'
      : 'Copying was blocked here. The instruction is selectable — click it once to select it all.';
    if (copyReset !== null) window.clearTimeout(copyReset);
    copyReset = window.setTimeout(() => {
      copyLabel.textContent = 'Copy';
      copyReset = null;
    }, 2400);
  });

  // Initial state from the query string: ?entry=github|plugin&step=<shareable step>
  let initialEntry = 'github';
  let initialStep = null;
  try {
    const params = new URL(window.location.href).searchParams;
    initialEntry = params.get('entry') || 'github';
    initialStep = params.get('step');
  } catch (error) {
    /* keep the defaults */
  }

  entry = ENTRIES.includes(initialEntry) ? initialEntry : 'github';
  goTo(SHAREABLE_STEPS.includes(initialStep) ? initialStep : defaultStep(), { focus: false });
})();
