/* DEBUG fake data only. Run after After.app --args --ui-test-fixture many:
 * osascript -l JavaScript scripts/maclab/task-flow.js
 * It never completes/cancels a task or changes projects; it adds one fake activity.
 * Output contains boolean assertions and a stage identifier, not app data.
 * A failed assertion throws sanitized JSON so osascript exits nonzero.
 * Use a fresh fixture; an existing sheet or nonempty composer aborts the run.
 */
ObjC.import('AppKit');
function run() {
    const start = Number($.NSProcessInfo.processInfo.systemUptime);
    const events = Application('System Events');
    const clipboard = $.NSPasteboard.generalPasteboard;
    const result = { ok: false, checks: {} };
    let stage = 'review_bundle';
    let process;
    let mainWindow;
    const fakeBody = 'UI 검증 진행 기록 · task-flow-' + Math.floor(start);
    function safe(read, fallback) { try { return read(); } catch (_) { return fallback; } }
    function tick() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - start > 65) throw new Error('deadline');
    }
    function pause() { tick(); delay(0.15); }
    function roots() {
        const windows = mainWindow ? [mainWindow] : process.windows();
        let sheets = [];
        windows.forEach(function (window) {
            sheets = sheets.concat(safe(function () { return window.sheets(); }, []));
        });
        return sheets.length ? sheets : windows;
    }
    function find(role, text, exact) {
        const queue = roots().map(function (node) { return { node: node, depth: 0 }; });
        let count = 0;
        while (queue.length && count++ < 700) {
            tick();
            const item = queue.shift(), node = item.node;
            const actualRole = safe(function () { return node.role(); }, '');
            if ((!role || role === actualRole) && (!text || [
                safe(function () { return node.name(); }, ''),
                safe(function () { return node.description(); }, ''),
                actualRole === 'AXStaticText' ? safe(function () { return node.value(); }, '') : ''
            ].some(function (label) { return typeof label === 'string' && (exact ? label === text : label.indexOf(text) >= 0); }))) return node;
            if (item.depth < 16) safe(function () { return node.uiElements(); }, []).forEach(function (child) {
                queue.push({ node: child, depth: item.depth + 1 });
            });
        }
        return null;
    }
    function need(role, text) { const node = find(role, text); if (!node) throw new Error('element_missing'); return node; }
    function activateMain() {
        $.NSRunningApplication.runningApplicationWithProcessIdentifier(process.unixId()).activateWithOptions(3);
        process.frontmost = true;
        safe(function () { mainWindow.actions.byName('AXRaise').perform(); }, null);
        safe(function () { mainWindow.attributes.byName('AXMain').value = true; }, null);
        safe(function () { mainWindow.attributes.byName('AXFocused').value = true; }, null);
        pause();
        if (!process.frontmost()) throw new Error('main_activation_failed');
    }
    function click(node) {
        if (!process.frontmost()) throw new Error('lost_foreground');
        try { node.actions.byName('AXPress').perform(); }
        catch (_) {
            try { events.click(node); }
            catch (_) {
                const point = node.position(), size = node.size();
                events.click({ at: [point[0] + size[0] / 2, point[1] + size[1] / 2] });
            }
        }
        pause();
    }
    function key(value) {
        if (!process.frontmost()) throw new Error('lost_foreground');
        events.keystroke(value, { using: ['command down'] }); pause();
    }
    function paste(text) {
        clipboard.clearContents;
        if (!clipboard.setStringForType($(text), $.NSPasteboardTypeString)) throw new Error('paste_failed');
        key('v');
    }
    function assert(name, truth) {
        result.checks[name] = Boolean(truth);
        if (!truth) throw new Error('assertion_failed');
    }
    try {
        const matches = events.processes.whose({ bundleIdentifier: 'dev.worklog.UIReview' })();
        if (matches.length !== 1) throw new Error('missing_review_bundle');
        process = matches[0];
        const candidates = process.windows().filter(function (window) {
            return safe(function () { return window.subrole(); }, '') === 'AXStandardWindow' &&
                ['빠른 입력', 'WorkLog 검색'].indexOf(safe(function () { return window.name(); }, '')) < 0;
        });
        if (!candidates.length) throw new Error('main_window_missing');
        mainWindow = candidates[0];
        activateMain();
        assert('reviewBundleFound', process.bundleIdentifier() === 'dev.worklog.UIReview');
        if (roots().some(function (node) { return safe(function () { return node.role(); }, '') === 'AXSheet'; })) {
            throw new Error('dismiss_existing_sheet_first');
        }
        stage = 'find_existing_task';
        const routeButton = find('AXButton', '업무', true);
        if (routeButton) click(routeButton);
        else key('2');
        click(need('AXTextField', '업무 이름 검색'));
        key('a');
        paste('배포 파이프라인');
        stage = 'select_first_filtered_task';
        const row = need('AXRow');
        try { row.selected = true; pause(); } catch (_) { click(row); }
        let open = need('AXButton', '선택한 업무 열기');
        if (!safe(function () { return open.enabled(); }, false)) { click(row); open = need('AXButton', '선택한 업무 열기'); }
        assert('taskSelected', safe(function () { return open.enabled(); }, false));
        click(open);
        stage = 'focus_activity_composer';
        click(need('AXButton', '진행 기록 추가'));
        let editor = find('AXTextArea', '진행 기록 내용') || need('AXTextArea');
        assert('blankComposerAvailable', safe(function () { return editor.value(); }, null) === '');
        click(editor);
        stage = 'enter_fake_activity';
        paste(fakeBody);
        assert('fakeBodyEntered', safe(function () { return editor.value(); }, null) === fakeBody);
        stage = 'save_activity';
        click(need('AXButton', '진행 기록 저장'));
        editor = find('AXTextArea', '진행 기록 내용') || need('AXTextArea');
        assert('draftClearedAfterSave', safe(function () { return editor.value(); }, null) === '');
        assert('savedActivityPresent', find('AXStaticText', fakeBody) !== null);
        stage = 'verify_after_reopen';
        click(need('AXButton', '닫기'));
        activateMain();
        click(need('AXButton', '선택한 업무 열기'));
        assert('activityPersistedAfterReopen', find('AXStaticText', fakeBody) !== null);
        stage = 'return_to_task_list';
        click(need('AXButton', '닫기'));
        activateMain();
        stage = 'complete';
        result.ok = true;
    } catch (_) { result.failureStage = stage; }
    result.stage = stage;
    result.finishedWithinBudget = Number($.NSProcessInfo.processInfo.systemUptime) - start < 90;
    if (!result.ok) throw new Error(JSON.stringify(result));
    return JSON.stringify(result);
}
