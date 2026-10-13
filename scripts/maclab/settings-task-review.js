/*
 * Narrow settings/task smoke checks for the isolated DEBUG many fixture.
 *   osascript -l JavaScript scripts/maclab/settings-task-review.js --action settings
 *   osascript -l JavaScript scripts/maclab/settings-task-review.js --action tasks
 *   osascript -l JavaScript scripts/maclab/settings-task-review.js --action capture
 *
 * Verifies the target PID's --ui-test-fixture many launch argument before input.
 * Does not save settings, alter task status, request login, call AI, or open Secret.
 * Only fixed synthetic titles, control labels and expected field values are read.
 * Uses native AX for controls and real paste for search. Clipboard receives fake
 * search text. Leaves the requested screen open for a screenshot; close capture
 * before running another action. Output is sanitized booleans and stage codes.
 * node --check is syntax validation only; macOS execution is required for a pass.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

function reviewRead(node, attribute) {
    if (!node) return null;
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function reviewString(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value);
    return typeof result === 'string' ? result : '';
}
function reviewText(node, attribute) { return reviewString(reviewRead(node, attribute)); }
function reviewArray(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    return result;
}

function run(args) {
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var result = { ok: false, checks: {}, secretValuesRead: false, settingsSaved: false };
    var stage = 'fixture_guard', appAX, reviewPID, running, events, root;
    var cancelledTitle = '다음 분기 운영 도구 접근성 검토';
    function fail(code) { var error = new Error(code); error.reviewCode = code; throw error; }
    function need(value, code) { if (!value) fail(code); return value; }
    function check(name, value) { result.checks[name] = Boolean(value); need(value, 'ASSERTION_' + name); }
    function tick() {
        need(Number($.NSProcessInfo.processInfo.systemUptime) - started < 55, 'WORKFLOW_DEADLINE');
    }
    function pause() { tick(); delay(0.15); }
    function waitFor(read, code) {
        var until = Number($.NSProcessInfo.processInfo.systemUptime) + 5;
        do {
            tick();
            var value = read();
            if (value) return value;
            delay(0.12);
        } while (Number($.NSProcessInfo.processInfo.systemUptime) < until);
        fail(code);
    }
    function windows() { return reviewArray(reviewRead(appAX, 'AXWindows')); }
    function windowNamed(title) {
        return windows().filter(function (node) { return reviewText(node, 'AXTitle') === title; })[0] || null;
    }
    function walk(container, visit) {
        var queue = [{ node: container, depth: 0 }], count = 0;
        while (queue.length && count++ < 1400) {
            tick();
            var item = queue.shift(), role = reviewText(item.node, 'AXRole');
            if (visit(item.node, role)) return item.node;
            if (item.depth < 28) reviewArray(reviewRead(item.node, 'AXChildren')).forEach(function (child) {
                queue.push({ node: child, depth: item.depth + 1 });
            });
        }
        need(queue.length === 0, 'AX_TRAVERSAL_LIMIT');
        return null;
    }
    function find(role, text, exact) {
        return walk(root, function (node, actualRole) {
            if (role && role !== actualRole) return false;
            var labels = [reviewText(node, 'AXTitle'), reviewText(node, 'AXDescription')];
            if (actualRole === 'AXStaticText') labels.push(reviewText(node, 'AXValue'));
            return labels.some(function (label) {
                return exact ? label === text : label.indexOf(text) >= 0;
            });
        });
    }
    function control(role, text, exact) { return need(find(role, text, exact), 'CONTROL_MISSING'); }
    function front() {
        return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
    }
    function press(node) {
        need(front(), 'LOST_FOREGROUND');
        need(Number($.AXUIElementPerformAction(node, $('AXPress'))) === 0, 'AX_PRESS_FAILED');
        pause();
    }
    function key(code, modifiers) {
        need(front(), 'LOST_FOREGROUND');
        events.keyCode(code, { using: modifiers || [] });
        pause();
    }
    function input(node, value) {
        need(front(), 'LOST_FOREGROUND');
        need(Number($.AXUIElementSetAttributeValue(node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'AX_FOCUS_FAILED');
        key(0, ['command down']);
        if (value) {
            var clipboard = $.NSPasteboard.generalPasteboard;
            clipboard.clearContents;
            need(clipboard.setStringForType($(value), $.NSPasteboardTypeString), 'PASTE_FAILED');
            key(9, ['command down']);
        } else key(51);
        waitFor(function () { return reviewText(node, 'AXValue') === value; }, 'SEARCH_TEXT_NOT_ENTERED');
    }
    function cancelledTaskRow() {
        return walk(root, function (node, role) {
            if (role !== 'AXButton') return false;
            return [reviewText(node, 'AXDescription'), reviewText(node, 'AXTitle')].some(function (label) {
                return label.indexOf(cancelledTitle) === 0;
            });
        });
    }
    try {
        need(args.length === 2 && args[0] === '--action' &&
            ['settings', 'tasks', 'capture'].indexOf(args[1]) >= 0, 'REQUIRE_ACTION');
        result.action = args[1];
        var apps = reviewArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return reviewString(app.bundleIdentifier) === 'dev.worklog.UIReview';
        });
        need(apps.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        running = apps[0]; reviewPID = Number(running.processIdentifier);
        need(isFinite(reviewPID) && reviewPID > 1 && Math.floor(reviewPID) === reviewPID, 'INVALID_REVIEW_PID');
        var automation = Application.currentApplication();
        automation.includeStandardAdditions = true;
        var launch = automation.doShellScript('/bin/ps -ww -p ' + reviewPID + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+many(?:\s|$)/.test(launch), 'REVIEW_LAUNCH_NOT_MANY_FIXTURE');
        need((launch.match(/--ui-test-fixture/g) || []).length === 1, 'AMBIGUOUS_FIXTURE_ARGUMENTS');
        launch = null;
        check('actualManyFixtureLaunchVerified', true);
        appAX = $.AXUIElementCreateApplication(reviewPID);
        $.AXUIElementSetMessagingTimeout(appAX, 0.5);
        need(!windowNamed('빠른 입력') && !windowNamed('WorkLog 검색'), 'CLOSE_EXISTING_PANELS_FIRST');
        var mainWindows = windows().filter(function (node) { return reviewText(node, 'AXSubrole') === 'AXStandardWindow'; });
        need(mainWindows.length === 1, 'EXACTLY_ONE_MAIN_WINDOW_REQUIRED');
        root = mainWindows[0];
        need(!reviewArray(reviewRead(root, 'AXSheets')).length &&
            !walk(root, function (_, role) { return role === 'AXSheet'; }), 'CLOSE_EXISTING_SHEET_FIRST');
        events = Application('System Events');
        running.activateWithOptions(3);
        $.AXUIElementPerformAction(root, $('AXRaise'));
        $.AXUIElementSetAttributeValue(root, $('AXMain'), $.kCFBooleanTrue);
        $.AXUIElementSetAttributeValue(root, $('AXFocused'), $.kCFBooleanTrue);
        waitFor(front, 'APP_NOT_ACTIVE');
        pause();

        if (result.action === 'settings') {
            stage = 'settings_navigation';
            key(43, ['command down']); // Command-comma.
            var settingsSearch = waitFor(function () { return find('AXTextField', '설정 항목 검색', true); }, 'SETTINGS_SEARCH_MISSING');
            check('settingsSearchPresent', settingsSearch);
            press(control('AXButton', '단축키', true));
            check('hotkeyRecorderVisible', find(null, '빠른 입력 단축키') !== null);
            check('noStandaloneRegisteredRow', find('AXStaticText', '등록됨', true) === null);
            stage = 'settings_search';
            input(settingsSearch, 'AI');
            check('aiSettingsNavigationFound', find('AXButton', 'AI 연결', true) !== null);
            press(control('AXButton', 'AI 연결', true));
            check('aiSettingsContentVisible', find(null, '일반 기록에 AI 사용') !== null);
            check('unrelatedShortcutNavigationFiltered', find('AXButton', '단축키', true) === null);
            input(settingsSearch, '모델');
            press(control('AXButton', '작업별 AI', true));
            check('taskModelPickerPresent', find(null, '주간보고 · 팀 제출용 모델', true) !== null);
            check('taskEffortPickerPresent', find(null, '주간보고 · 팀 제출용 사고 수준', true) !== null);
            input(settingsSearch, '');
            check('settingsNavigationRestored', find('AXButton', '단축키', true) !== null);
        } else if (result.action === 'tasks') {
            stage = 'closed_tasks_default';
            key(19, ['command down']); // Command-2: tasks.
            var taskSearch = waitFor(function () { return find('AXTextField', '업무 이름 검색', true); }, 'TASK_SEARCH_MISSING');
            input(taskSearch, '');
            check('cancelledTaskHiddenByDefault', cancelledTaskRow() === null);
            stage = 'closed_tasks_search';
            input(taskSearch, cancelledTitle);
            check('cancelledTaskSearchable', waitFor(cancelledTaskRow, 'CANCELLED_HISTORY_NOT_SEARCHABLE'));
            input(taskSearch, '');
            check('cancelledTaskHiddenAfterClearingSearch', cancelledTaskRow() === null);
            stage = 'closed_tasks_toggle';
            var closed = find('AXButton', '완료·취소 업무');
            if (!closed) {
                // LazyVStack may omit controls below the viewport from AX.
                // End scrolls the list after Down transfers focus from search.
                key(125);
                key(119);
                closed = waitFor(function () { return find('AXButton', '완료·취소 업무'); }, 'CLOSED_SECTION_NOT_FOUND');
            }
            check('closedSectionInitiallyCollapsed', reviewText(closed, 'AXValue') === '접힘');
            press(closed);
            check('closedSectionExpanded', waitFor(function () {
                return reviewText(control('AXButton', '완료·취소 업무'), 'AXValue') === '펼쳐짐';
            }, 'CLOSED_SECTION_NOT_EXPANDED'));
            press(control('AXButton', '완료·취소 업무'));
            check('closedSectionCollapsedAgain', reviewText(control('AXButton', '완료·취소 업무'), 'AXValue') === '접힘');
            check('cancelledTaskHiddenAfterCollapse', cancelledTaskRow() === null);
        } else {
            stage = 'capture_tasks';
            key(45, ['command down']); // Command-N.
            root = waitFor(function () { return windowNamed('빠른 입력'); }, 'CAPTURE_NOT_OPEN');
            key(19, ['command down']); // Command-2: capture task tab.
            var captureSearch = waitFor(function () {
                return find('AXTextField', '업무 검색 또는 새 업무 이름', true);
            }, 'CAPTURE_TASK_SEARCH_MISSING');
            check('cancelledTaskAbsentFromDefaultCapture', cancelledTaskRow() === null);
            input(captureSearch, cancelledTitle);
            check('cancelledTaskAbsentFromCaptureSearch', cancelledTaskRow() === null);
            check('newTaskActionRemainsAvailable', find('AXButton', '새 업무 만들기') !== null);
            input(captureSearch, '');
            check('captureStillHasActiveTaskSuggestions', find('AXButton', '배포 파이프라인') !== null);
        }
        stage = 'complete';
        result.ok = true;
    } catch (error) {
        result.failureStage = stage;
        result.errorCode = error.reviewCode || 'AX_OR_AUTOMATION_FAILURE';
    }
    result.stage = stage;
    result.finishedWithinBudget = Number($.NSProcessInfo.processInfo.systemUptime) - started < 60;
    if (!result.ok) throw new Error(JSON.stringify(result));
    return JSON.stringify(result);
}
