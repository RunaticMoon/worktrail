/* Native source-activity checks for a disposable DEBUG fixture only.
 * caffeinate -du osascript -l JavaScript scripts/maclab/source-activities-check.js --pid PID --fixture many|few|empty
 * Requires dev.worklog.UIReview.SourceActivities in /tmp/WorkLogSourceActivityReview-*
 * and the exact --ui-test-fixture launch argument. No network, credentials, clipboard,
 * recording, settings changes, or record edits. Captures only the owned app's windows.
 * node --check validates syntax only; a macOS fixture run is required for a UI pass.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

function read(node, attribute) {
    if (!node) return null;
    var result = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), result)) !== 0) return null;
    return ObjC.castRefToObject(result[0]);
}
function string(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value); return typeof result === 'string' ? result : '';
}
function text(node, attribute) { return string(read(node, attribute)); }
function array(value) {
    if (value === null || value === undefined) return [];
    var count = Number(value.count), result = [];
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE');
    for (var index = 0; index < count; index++) result.push(value.objectAtIndex(index));
    return result;
}

function run(args) {
    var start = Number($.NSProcessInfo.processInfo.systemUptime), stage = 'guard', canCaptureFailure = false;
    var result = {ok: false, checks: {}, networkUsed: false, credentialsUsed: false, recordsEdited: false};
    function need(value, code) { if (!value) throw new Error(code); return value; }
    function check(name, value) { result.checks[name] = Boolean(value); need(value, 'ASSERT_' + name); }
    function tick() { need(Number($.NSProcessInfo.processInfo.systemUptime) - start < 55, 'DEADLINE'); }
    function pause() { tick(); delay(0.18); }
    function wait(find, code) {
        var deadline = Number($.NSProcessInfo.processInfo.systemUptime) + 5;
        do { tick(); var value = find(); if (value) return value; pause(); }
        while (Number($.NSProcessInfo.processInfo.systemUptime) < deadline);
        throw new Error(code);
    }
    try {
        need(args.length === 4 && args[0] === '--pid' && args[2] === '--fixture', 'ARGUMENTS');
        var pid = Number(args[1]), fixture = args[3];
        need(Number.isInteger(pid) && pid > 1, 'PID');
        need(['many', 'few', 'empty'].indexOf(fixture) >= 0, 'FIXTURE_NAME');
        var app = need($.NSRunningApplication.runningApplicationWithProcessIdentifier(pid), 'RUNNING_APP');
        need(string(app.bundleIdentifier) === 'dev.worklog.UIReview.SourceActivities', 'FIXTURE_BUNDLE');
        var path = string(app.bundleURL.path);
        need(/^\/(?:private\/)?tmp\/WorkLogSourceActivityReview-[^/]+\/.+\.app$/.test(path), 'FIXTURE_PATH');
        var automation = Application.currentApplication(); automation.includeStandardAdditions = true;
        var command = automation.doShellScript('/bin/ps -ww -p ' + pid + ' -o command=');
        need(new RegExp('(?:^|\\s)--ui-test-fixture\\s+' + fixture + '(?:\\s|$)').test(command), 'FIXTURE_ARGUMENT');
        need((command.match(/--ui-test-fixture/g) || []).length === 1, 'FIXTURE_ARGUMENT_UNIQUE');
        check('isolatedFixture', true);
        need(Boolean($.AXIsProcessTrusted()), 'ACCESSIBILITY_UNAVAILABLE');
        var ax = $.AXUIElementCreateApplication(pid), events = Application('System Events');
        $.AXUIElementSetMessagingTimeout(ax, 0.5);
        function sessionAllowed() {
            var session = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary()));
            var locked = session.CGSSessionScreenIsLocked;
            need(locked === undefined || locked === false || locked === 0, 'SCREEN_LOCKED');
            need(Boolean(session.kCGSSessionOnConsoleKey) && Boolean(session.kCGSessionLoginDoneKey), 'CONSOLE_UNAVAILABLE');
        }
        function front() { return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid; }
        function inputAllowed() { sessionAllowed(); need(front(), 'FOREGROUND'); }
        function windows() { return array(read(ax, 'AXWindows')); }
        function roots() {
            var values = windows();
            values.slice().forEach(function (window) { values = values.concat(array(read(window, 'AXSheets'))); });
            return values;
        }
        function walk(root, visit) {
            var queue = [{node: root, depth: 0}], count = 0;
            while (queue.length && count++ < 1800) {
                tick(); var item = queue.shift(), role = text(item.node, 'AXRole');
                if (visit(item.node, role)) return item.node;
                if (item.depth < 30) array(read(item.node, 'AXChildren')).forEach(function (node) {
                    queue.push({node: node, depth: item.depth + 1});
                });
            }
            need(!queue.length, 'AX_TRAVERSAL_LIMIT');
            return null;
        }
        function find(test) {
            for (var root of roots()) { var match = walk(root, test); if (match) return match; }
            return null;
        }
        function identifier(value) { return find(function (node) { return text(node, 'AXIdentifier') === value; }); }
        function labelled(value, role) {
            return find(function (node, actualRole) {
                if (role && actualRole !== role) return false;
                return [text(node, 'AXTitle'), text(node, 'AXDescription'), text(node, 'AXValue')].some(function (label) { return label === value; });
            });
        }
        function enabledAction(id, label, roles) {
            function usable(node) {
                if (!node || roles.indexOf(text(node, 'AXRole')) < 0) return false;
                var enabled = read(node, 'AXEnabled');
                return enabled !== null && Boolean(ObjC.unwrap(enabled));
            }
            var identified = identifier(id);
            if (usable(identified)) return identified;
            for (var role of roles) {
                var match = labelled(label, role);
                if (usable(match)) return match;
            }
            return null;
        }
        function containsText(value) {
            return find(function (node, role) {
                return role === 'AXStaticText' && [text(node, 'AXValue'), text(node, 'AXDescription')].some(function (label) { return label.indexOf(value) >= 0; });
            });
        }
        function key(code, modifiers) { inputAllowed(); events.keyCode(code, {using: modifiers || []}); pause(); }
        function selectedSource(source) {
            return find(function (node, role) {
                return role === 'AXButton' && text(node, 'AXIdentifier').indexOf('day.source.' + source + '.') === 0 &&
                    text(node, 'AXValue') === '선택됨';
            });
        }
        function sourceRow(source, titlePart) {
            return find(function (node, role) {
                return role === 'AXButton' && text(node, 'AXIdentifier').indexOf('day.source.' + source + '.') === 0 &&
                    [text(node, 'AXDescription'), text(node, 'AXTitle')].some(function (label) { return label.indexOf(titlePart) >= 0; });
            });
        }
        function selectionDiagnostic(source, moment) {
            var selected = selectedSource(source), focused = read(ax, 'AXFocusedUIElement'), rows = [];
            find(function (node, role) {
                var id = text(node, 'AXIdentifier');
                if (role === 'AXButton' && id.indexOf('day.source.' + source + '.') === 0) {
                    rows.push({identifier: id, value: text(node, 'AXValue')});
                }
                return false;
            });
            if (!result.selectionDiagnostics) result.selectionDiagnostics = [];
            result.selectionDiagnostics.push({source: source, moment: moment,
                selectedIdentifier: text(selected, 'AXIdentifier'), rows: rows,
                focusedRole: text(focused, 'AXRole'), focusedIdentifier: text(focused, 'AXIdentifier')});
        }
        function waitForSelection(source, predicate, code, moment) {
            try {
                return wait(function () {
                    var selected = selectedSource(source);
                    return selected && predicate(text(selected, 'AXIdentifier')) ? selected : null;
                }, code);
            } finally { selectionDiagnostic(source, moment); }
        }
        function capture(name) {
            inputAllowed();
            var info = array(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
            var owned = info.filter(function (item) {
                var bounds = ObjC.deepUnwrap(item.objectForKey('kCGWindowBounds'));
                return Number(ObjC.unwrap(item.objectForKey('kCGWindowOwnerPID'))) === pid && bounds.Width >= 300 && bounds.Height >= 200;
            });
            need(owned.length, 'SCREENSHOT_OWN_WINDOW');
            var id = Number(ObjC.unwrap(owned[0].objectForKey('kCGWindowNumber')));
            need(Number.isInteger(id) && id > 0, 'SCREENSHOT_ID');
            var destination = path.replace(/\/[^/]+\.app$/, '') + '/' + fixture + '-' + name + '.png';
            automation.doShellScript('/usr/sbin/screencapture -x -o -l ' + id + " '" + destination.replace(/'/g, "'\\''") + "'");
            if (!result.screenshots) result.screenshots = [];
            result.screenshots.push(destination);
        }
        function count(region) {
            var node = need(identifier('day.region.' + region), 'TAB_' + region);
            var label = text(node, 'AXDescription') || text(node, 'AXTitle');
            var match = label.match(/,\s*(\d+)개/);
            return Number(need(match, 'COUNT_' + region)[1]);
        }
        sessionAllowed(); app.activateWithOptions(3);
        var main = need(windows().filter(function (node) { return text(node, 'AXSubrole') === 'AXStandardWindow'; })[0], 'MAIN_WINDOW');
        $.AXUIElementPerformAction(main, $('AXRaise'));
        $.AXUIElementSetAttributeValue(main, $('AXMain'), $.kCFBooleanTrue);
        $.AXUIElementSetAttributeValue(main, $('AXFocused'), $.kCFBooleanTrue);
        wait(front, 'ACTIVATE');
        canCaptureFailure = true;
        // Resume only an identified source overview left open by a prior failed run.
        // Existing editors and other panels still require explicit cleanup by their owner.
        if (identifier('source-activity.body')) {
            key(53);
            wait(function () { return !identifier('source-activity.body'); }, 'PRIOR_SOURCE_DETAIL_CLOSE');
        }
        need(!labelled('빠른 입력 닫기', 'AXButton') && !find(function (_, role) { return role === 'AXSheet'; }), 'CLOSE_EXISTING_PANELS');

        stage = 'counts';
        key(18, ['command down']);
        key(18, ['command down', 'option down']);
        wait(function () { return labelled('활동 기록 목록', 'AXScrollArea'); }, 'TIMELINE');
        var sourceCount = fixture === 'empty' ? 0 : 2;
        check('githubCount', count('github') === sourceCount);
        check('jiraCount', count('jira') === sourceCount);
        check('memoCountExcludesImported', count('memos') === (fixture === 'many' ? 37 : fixture === 'few' ? 3 : 0));
        if (fixture === 'many') check('timelineIncludesAllRecords', count('timeline') === 75);
        if (fixture !== 'empty') {
            check('timelineUsesSourceRows', sourceRow('github', 'PR #77 병합됨') && sourceRow('jira', 'PROJECT-77'));
            check('timelineOmitsLongSourceBody', !containsText('수집 원문 1:'));
        }
        capture('timeline');

        stage = 'five_region_keyboard';
        var regionLabels = ['활동 기록 목록', '하루 업무 목록', '하루 메모 목록', 'GitHub 활동 목록', 'Jira 활동 목록'];
        for (var index = 1; index <= regionLabels.length; index++) {
            key(48, ['control down']);
            wait(function () { return labelled(regionLabels[index % regionLabels.length], 'AXScrollArea'); }, 'FORWARD_REGION_' + index);
        }
        key(48, ['control down', 'shift down']);
        wait(function () { return labelled('Jira 활동 목록', 'AXScrollArea'); }, 'REVERSE_JIRA');
        key(48, ['control down', 'shift down']);
        wait(function () { return labelled('GitHub 활동 목록', 'AXScrollArea'); }, 'REVERSE_GITHUB');
        check('fiveRegionCycle', true);

        stage = 'source_detail_keyboard';
        function verifySource(source, keyCode, titlePart) {
            key(keyCode, ['command down', 'option down']);
            wait(function () { return identifier('day.source-list.' + source); }, 'SOURCE_LIST_' + source);
            if (fixture === 'empty') {
                key(125); key(36);
                check(source + 'EmptyReturnSafe', !identifier('source-activity.detail'));
                capture(source + '-empty'); return;
            }
            check(source + 'CompactTitle', sourceRow(source, titlePart) !== null);
            check(source + 'LongBodyHidden', !containsText('수집 원문 1:'));
            var first = text(sourceRow(source, titlePart), 'AXIdentifier');
            // A previous failed run may have left the second row selected.
            key(126);
            waitForSelection(source, function (id) { return id === first; }, 'INITIAL_SELECTION_' + source, 'beforeDown');
            key(125);
            check(source + 'ArrowSelection', Boolean(waitForSelection(source, function (id) { return id !== first; }, 'DOWN_' + source, 'afterDown')));
            key(126);
            check(source + 'ArrowBack', Boolean(waitForSelection(source, function (id) { return id === first; }, 'UP_' + source, 'afterUp')));
            capture(source + '-list');
            key(36);
            wait(function () { return identifier('source-activity.body'); }, 'DETAIL_' + source);
            check(source + 'FullBody', containsText('수집 원문 12:') !== null);
            check(source + 'OriginalLink', enabledAction('source-activity.original-link',
                (source === 'github' ? 'GitHub' : 'Jira') + '에서 원본 열기', ['AXLink', 'AXButton']) !== null);
            check(source + 'EditAndLinkAction', enabledAction('source-activity.edit', '기록 편집 · 업무 연결', ['AXButton']) !== null);
            capture(source + '-detail');
            key(53);
            wait(function () { return !identifier('source-activity.body'); }, 'DETAIL_CLOSE_' + source);
            check(source + 'SelectionRestored', text(wait(function () { return selectedSource(source); }, 'RESTORED_' + source), 'AXIdentifier') === first);
        }
        verifySource('github', 21, 'PR #77 병합됨');
        verifySource('jira', 23, 'PROJECT-77 · 진행 중 → 완료');
        stage = 'memo_separation';
        key(20, ['command down', 'option down']);
        wait(function () { return labelled('하루 메모 목록', 'AXScrollArea'); }, 'MEMO_LIST');
        check('sourceRowsAbsentFromMemos', !sourceRow('github', '') && !sourceRow('jira', ''));
        capture('memos');
        result.ok = true; result.stage = stage; result.fixture = fixture;
        return JSON.stringify(result);
    } catch (error) {
        result.stage = stage; result.error = String(error.message || error);
        if (canCaptureFailure) {
            try { capture('failure-' + stage); }
            catch (captureError) { result.failureCaptureError = String(captureError.message || captureError); }
        }
        throw new Error(JSON.stringify(result));
    }
}
