/* Run on Maclab after launching After.app --args --ui-test-fixture few|many.
 * osascript -l JavaScript scripts/maclab/secret-flow.js --fixture many
 * Bundle lookup is deliberate: this helper must never target the production app.
 * Optional --action open|copy|edit runs an atomic phase; phases after open assume
 * the fake development settings record remains selected in the Secret screen.
 * Output contains booleans/stage identifiers only, never clipboard or AX values.
 * A failed assertion throws sanitized JSON so osascript exits nonzero.
 * Run open, copy, edit in that order when using atomic phases on one fresh fixture.
 */
ObjC.import('AppKit');

function run(args) {
    const started = Number($.NSProcessInfo.processInfo.systemUptime);
    let stage = 'fixture_guard';
    const report = { ok: false, tests: {} };
    const fixtureIndex = args.indexOf('--fixture');
    const fixture = fixtureIndex >= 0 ? args[fixtureIndex + 1] : null;
    const actionIndex = args.indexOf('--action');
    const action = actionIndex >= 0 ? args[actionIndex + 1] : 'all';
    const events = Application('System Events');
    const clipboard = $.NSPasteboard.generalPasteboard;
    let process;
    let mainWindow;
    function checkTime() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - started > 72) throw new Error('deadline');
    }
    function safe(read, fallback) { try { return read(); } catch (_) { return fallback; } }
    function pause() { checkTime(); delay(0.2); }
    function labels(node) {
        // AX descriptions are accessible labels; never request AXValue/field values.
        return [safe(function () { return node.name(); }, ''),
            safe(function () { return node.description(); }, '')].filter(function (item) { return typeof item === 'string'; });
    }
    function find(predicate) {
        const roots = mainWindow ? [mainWindow] : process.windows();
        const queue = roots.map(function (node) { return { node: node, parents: [] }; });
        let count = 0;
        while (queue.length && count < 900) {
            checkTime();
            const current = queue.shift();
            count += 1;
            const role = safe(function () { return current.node.role(); }, '');
            if (predicate(current.node, role)) return current;
            if (current.parents.length < 16) {
                safe(function () { return current.node.uiElements(); }, []).forEach(function (node) {
                    queue.push({ node: node, parents: current.parents.concat([current.node]) });
                });
            }
        }
        return null;
    }
    function named(label, role, contains) {
        return find(function (node, actualRole) {
            if (role && actualRole !== role) return false;
            return labels(node).some(function (text) { return contains ? text.indexOf(label) >= 0 : text === label; });
        });
    }
    function requireNamed(label, role, contains) {
        const result = named(label, role, contains);
        if (!result) throw new Error('element_missing');
        return result;
    }
    function activateMain() {
        $.NSRunningApplication.runningApplicationWithProcessIdentifier(process.unixId()).activateWithOptions(3);
        process.frontmost = true;
        safe(function () { mainWindow.actions.byName('AXRaise').perform(); }, null);
        safe(function () { mainWindow.attributes.byName('AXMain').value = true; }, null);
        safe(function () { mainWindow.attributes.byName('AXFocused').value = true; }, null);
        pause();
        foreground();
    }
    function foreground() {
        if (!process.frontmost()) throw new Error('lost_foreground');
    }
    function press(node) {
        foreground();
        try { node.actions.byName('AXPress').perform(); }
        catch (_) {
            try { events.click(node); }
            catch (_) {
                // A standard list's static text has no AXPress. Use its live AX frame.
                const point = node.position(), size = node.size();
                events.click({ at: [point[0] + size[0] / 2, point[1] + size[1] / 2] });
            }
        }
        pause();
    }
    function key(value, modifiers) {
        foreground();
        if (typeof value === 'number') events.keyCode(value, { using: modifiers || [] });
        else events.keystroke(value, { using: modifiers || [] });
        pause();
    }
    function pasteFake(text) {
        clipboard.clearContents;
        if (!clipboard.setStringForType($(text), $.NSPasteboardTypeString)) throw new Error('pasteboard_write_failed');
        key('a', ['command down']);
        key('v', ['command down']);
    }
    function clipboardEquals(expected) {
        return safe(function () { return ObjC.unwrap(clipboard.stringForType($.NSPasteboardTypeString)) === expected; }, false);
    }
    function count() { return Number(clipboard.changeCount); }
    function assert(name, value) {
        report.tests[name] = Boolean(value);
        if (!value) throw new Error('assertion_failed');
    }
    function copyRow(number) {
        press(requireNamed('DEMO_SETTING_' + number + ' 값 복사', 'AXButton', false).node);
    }
    try {
        if (['few', 'many'].indexOf(fixture) < 0 || ['all', 'open', 'copy', 'edit'].indexOf(action) < 0) throw new Error('invalid_mode');
        stage = 'locate_review_bundle';
        const matches = events.processes.whose({ bundleIdentifier: 'dev.worklog.UIReview' })();
        if (matches.length !== 1) throw new Error('ambiguous_review_process');
        process = matches[0];
        const candidates = process.windows().filter(function (window) {
            return safe(function () { return window.subrole(); }, '') === 'AXStandardWindow' &&
                ['빠른 입력', 'WorkLog 검색'].indexOf(safe(function () { return window.name(); }, '')) < 0;
        });
        if (!candidates.length) throw new Error('main_window_missing');
        mainWindow = candidates[0];
        if (safe(function () { return mainWindow.sheets().length > 0; }, false)) throw new Error('dismiss_existing_sheet_first');
        activateMain();
        assert('reviewBundleFound', process.bundleIdentifier() === 'dev.worklog.UIReview');
        if (action === 'all' || action === 'open') {
            stage = 'open_secret_route';
            const routeButton = named('Secret', 'AXButton', false);
            if (routeButton) press(routeButton.node);
            else key('6', ['command down']);
            stage = 'unlock_mock_vault';
            const unlock = named('잠금 해제', 'AXButton', false);
            if (unlock) press(unlock.node);
            assert('vaultUnlocked', named('지금 잠금', 'AXButton', false) !== null);
            stage = 'search_fake_title';
            press(requireNamed('Secret 제목 검색', 'AXTextField', false).node);
            pasteFake('가짜 개발 환경 설정');
            stage = 'select_fake_title';
            const title = requireNamed('가짜 개발 환경 설정', null, true);
            const rows = title.parents.filter(function (node) { return safe(function () { return node.role(); }, '') === 'AXRow'; });
            if (rows.length) {
                const row = rows[rows.length - 1];
                try { row.selected = true; pause(); } catch (_) { press(row); }
            } else { press(title.node); }
            assert('fakeRecordOpened', named('DEMO_SETTING_1 값 복사', 'AXButton', false) !== null);
            assert('valuesMasked', named('DEMO_SETTING_1, 값 가려짐', 'AXButton', true) !== null);
        }
        if (action === 'all' || action === 'copy') {
            stage = 'explicit_first_row_copy';
            const beforeCopy = count();
            copyRow(1);
            assert('explicitCopyChangedClipboard', count() !== beforeCopy);
            assert('firstFakeValueMatches', clipboardEquals('fake-ui-only-updated'));
            stage = 'arrow_selection_does_not_copy';
            const beforeArrow = count();
            key(125); // Down: focus changes, clipboard must not.
            assert('arrowDidNotCopy', count() === beforeArrow);
            stage = 'return_copies_selected_row';
            key(36);
            assert('returnCopiedSecondFakeValue', clipboardEquals('fake-ui-only-value-2'));
        }
        if (action === 'all' || action === 'edit') {
            stage = 'enter_explicit_edit_mode';
            press(requireNamed('편집', 'AXButton', false).node);
            assert('editModeOpened', named('Secret 편집', null, false) !== null);
            stage = 'edit_cell_click_does_not_copy';
            const valueField = requireNamed('가려진 값', 'AXTextField', false).node;
            const beforeCellClick = count();
            press(valueField);
            assert('editClickDidNotCopy', count() === beforeCellClick);
            stage = 'paste_fake_partial_change';
            pasteFake('  fake-ui-local-edit-only  ');
            stage = 'save_partial_change';
            key('s', ['command down']);
            assert('returnedToReadMode', named('DEMO_SETTING_1 값 복사', 'AXButton', false) !== null);
            stage = 'verify_trimmed_first_value';
            copyRow(1);
            assert('savedFirstValueTrimmed', clipboardEquals('fake-ui-local-edit-only'));
            stage = 'verify_untouched_second_value';
            copyRow(2);
            assert('secondValuePreserved', clipboardEquals('fake-ui-only-value-2'));
            assert('valuesRemainMasked', named('DEMO_SETTING_1, 값 가려짐', 'AXButton', true) !== null);
        }
        stage = 'complete';
        report.ok = true;
    } catch (_) {
        report.failureStage = stage;
    }
    report.stage = stage;
    report.finishedWithinBudget = Number($.NSProcessInfo.processInfo.systemUptime) - started < 90;
    if (!report.ok) throw new Error(JSON.stringify(report));
    return JSON.stringify(report);
}
