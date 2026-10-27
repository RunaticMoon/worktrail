/* Native UI checks for a disposable DEBUG fixture only.
 * osascript -l JavaScript scripts/maclab/workflow-enhancements-check.js --pid PID --action inspect|settings|due|secret|reports|windows
 * Requires a /tmp/WorkLogUIReview- directory, dev.worklog.UIReview.Workflow013,
 * verified --ui-test-fixture many, and the exact PID.
 * Never launches OAuth, stores credentials, starts recording, or targets production.
 * The fixture guard and locked-session refusal were executed on macOS; workflow
 * actions still require validation in an unlocked console session.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

function read(node, attribute) {
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function string(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value); return typeof result === 'string' ? result : '';
}
function text(node, attribute) { return string(read(node, attribute)); }
function array(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    for (var index = 0; index < count; index++) result.push(value.objectAtIndex(index));
    return result;
}

function run(args) {
    var start = Number($.NSProcessInfo.processInfo.systemUptime), stage = 'guard';
    var result = {ok: false, checks: {}, realMicrophoneOpened: false, credentialsEntered: false};
    function need(value, code) { if (!value) throw new Error(code); return value; }
    function check(name, value) { result.checks[name] = Boolean(value); need(value, 'ASSERT_' + name); }
    function tick() { need(Number($.NSProcessInfo.processInfo.systemUptime) - start < 55, 'DEADLINE'); }
    function pause() { tick(); delay(0.2); }
    function wait(find, code) {
        var deadline = Number($.NSProcessInfo.processInfo.systemUptime) + 6;
        do { var value = find(); if (value) return value; pause(); } while (Number($.NSProcessInfo.processInfo.systemUptime) < deadline);
        throw new Error(code);
    }
    try {
        need(args.length === 4 && args[0] === '--pid' && args[2] === '--action', 'ARGUMENTS');
        var pid = Number(args[1]), action = args[3];
        need(Number.isInteger(pid) && pid > 1, 'PID');
        var app = need($.NSRunningApplication.runningApplicationWithProcessIdentifier(pid), 'RUNNING_APP');
        need(string(app.bundleIdentifier) === 'dev.worklog.UIReview.Workflow013', 'FIXTURE_BUNDLE');
        var path = string(app.bundleURL.path);
        need(/^\/private\/tmp\/WorkLogUIReview-|^\/tmp\/WorkLogUIReview-/.test(path), 'TEMP_FIXTURE_PATH');
        var automation = Application.currentApplication(); automation.includeStandardAdditions = true;
        var command = automation.doShellScript('/bin/ps -ww -p ' + pid + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+many(?:\s|$)/.test(command), 'FIXTURE_ARGUMENT');
        need((command.match(/--ui-test-fixture/g) || []).length === 1, 'FIXTURE_ARGUMENT_UNIQUE');
        check('isolatedManyFixture', true);
        var nativeSession = $.CGSessionCopyCurrentDictionary();
        var session = nativeSession ? ObjC.deepUnwrap(ObjC.castRefToObject(nativeSession)) : {};
        result.consoleSession = {
            onConsole: Boolean(session.kCGSSessionOnConsoleKey),
            loginDone: Boolean(session.kCGSessionLoginDoneKey),
            locked: Boolean(session.CGSSessionScreenIsLocked),
            accessibilityTrusted: Boolean($.AXIsProcessTrusted())
        };
        if (action !== 'inspect' && action !== 'windows') {
            need(result.consoleSession.accessibilityTrusted, 'ACCESSIBILITY_UNAVAILABLE');
            need(result.consoleSession.onConsole && result.consoleSession.loginDone, 'CONSOLE_UNAVAILABLE');
            need(!result.consoleSession.locked, 'SCREEN_LOCKED');
        }
        var ax = $.AXUIElementCreateApplication(pid), events = Application('System Events');
        $.AXUIElementSetMessagingTimeout(ax, 0.5);
        function windows() { return array(read(ax, 'AXWindows')); }
        function walk(root, visit) {
            var queue = [{node: root, depth: 0}], count = 0;
            while (queue.length && count++ < 1800) {
                tick(); var item = queue.shift(), role = text(item.node, 'AXRole');
                if (visit(item.node, role)) return item.node;
                if (item.depth < 30) array(read(item.node, 'AXChildren')).forEach(function (child) { queue.push({node: child, depth: item.depth + 1}); });
            }
            return null;
        }
        function find(role, label, exact) {
            for (var window of windows()) {
                var match = walk(window, function (node, actualRole) {
                    if (role && role !== actualRole) return false;
                    var values = [text(node, 'AXTitle'), text(node, 'AXDescription'), text(node, 'AXIdentifier')];
                    if (actualRole === 'AXStaticText') values.push(text(node, 'AXValue'));
                    return values.some(function (value) { return exact ? value === label : value.indexOf(label) >= 0; });
                });
                if (match) return match;
            }
            return null;
        }
        function control(role, label, exact) { return need(find(role, label, exact), 'MISSING_' + label); }
        function front() { return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid; }
        function press(node) { need(front(), 'FOREGROUND'); need(Number($.AXUIElementPerformAction(node, $('AXPress'))) === 0, 'PRESS'); pause(); }
        function key(code, modifiers) { need(front(), 'FOREGROUND'); events.keyCode(code, {using: modifiers || []}); pause(); }
        function focused(node) { var value = read(node, 'AXFocused'); return value !== null && Boolean(ObjC.unwrap(value)); }
        function focus(node) { need(Number($.AXUIElementSetAttributeValue(node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'FOCUS'); pause(); }
        function input(node, value) {
            focus(node); key(0, ['command down']);
            var board = $.NSPasteboard.generalPasteboard; board.clearContents;
            need(board.setStringForType($(value), $.NSPasteboardTypeString), 'FAKE_PASTE'); key(9, ['command down']);
        }
        function activate() {
            if (!windows().length) {
                var openMain = walk(ax, function (node, role) { return role === 'AXMenuItem' && text(node, 'AXTitle') === 'WorkLog 열기'; });
                need(openMain, 'OPEN_MAIN_MENU');
                need(Number($.AXUIElementPerformAction(openMain, $('AXPress'))) === 0, 'OPEN_MAIN');
                wait(function () { return windows().length > 0; }, 'MAIN_WINDOW');
            }
            app.activateWithOptions(3);
            var main = windows().filter(function (window) { return text(window, 'AXSubrole') === 'AXStandardWindow'; })[0];
            if (main) { $.AXUIElementPerformAction(main, $('AXRaise')); $.AXUIElementSetAttributeValue(main, $('AXMain'), $.kCFBooleanTrue); }
            var processes = events.processes.whose({unixId: pid})();
            need(processes.length === 1, 'FIXTURE_PROCESS');
            processes[0].frontmost = true;
            var nativeWindows = processes[0].windows();
            if (nativeWindows.length) {
                var position = nativeWindows[0].position(), size = nativeWindows[0].size();
                var point = $.CGPointMake(position[0] + size[0] / 2, position[1] + 12);
                $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
                $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
            }
            wait(front, 'ACTIVATE');
        }
        if (action !== 'inspect' && action !== 'windows') activate();
        stage = action;
        result.windowCount = windows().length;
        result.foreground = front();
        if (action === 'inspect') {
            result.controls = [];
            for (var window of windows()) walk(window, function (node, role) {
                if (['AXButton', 'AXCheckBox', 'AXPopUpButton', 'AXTextField', 'AXDisclosureTriangle', 'AXImage', 'AXIncrementor'].indexOf(role) >= 0) {
                    result.controls.push({role: role, label: text(node, 'AXTitle') || text(node, 'AXDescription'), id: text(node, 'AXIdentifier')});
                }
                return false;
            });
        } else if (action === 'windows') {
            ObjC.import('CoreGraphics');
            var info = array(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
            result.windows = info.filter(function (item) { return Number(ObjC.unwrap(item.objectForKey('kCGWindowOwnerPID'))) === pid; }).map(function (item) {
                return {id: Number(ObjC.unwrap(item.objectForKey('kCGWindowNumber'))), layer: Number(ObjC.unwrap(item.objectForKey('kCGWindowLayer')))};
            });
        } else if (action === 'settings') {
            key(43, ['command down']);
            press(wait(function () { return find('AXButton', 'AI 연결', true); }, 'AI_NAV'));
            check('cliPathField', find('AXTextField', 'Codex CLI 실행 파일') !== null);
            var picker = control('AXPopUpButton', 'AI 연결 방식'); press(picker);
            press(wait(function () { return find('AXMenuItem', 'OpenAI Compatible', false); }, 'COMPATIBLE_OPTION'));
            check('compatibleBaseURL', find('AXTextField', 'API 기본 URL') !== null);
            check('deepSeekPreset', find('AXButton', 'DeepSeek 기본값 사용', true) !== null);
            press(control('AXButton', 'DeepSeek 기본값 사용', true));
            check('deepSeekURL', text(control('AXTextField', 'API 기본 URL'), 'AXValue') === 'https://api.deepseek.com');
            press(control('AXPopUpButton', 'AI 연결 방식'));
            press(wait(function () { return find('AXMenuItem', 'Codex CLI', false); }, 'CLI_OPTION'));
            press(control('AXButton', '활동 수집', true));
            press(control('AXDisclosureTriangle', 'GitHub Enterprise', false));
            press(control('AXDisclosureTriangle', 'Jira Cloud', false));
            check('githubHost', find('AXTextField', 'https://github.company.com') !== null);
            check('jiraHost', find('AXTextField', 'https://company.atlassian.net') !== null);
            check('jiraJQL', find('AXTextField', '수집할 이슈 JQL') !== null || find('AXTextArea', '수집할 이슈 JQL') !== null);
            check('manualImport', find('AXButton', '지금 가져오기', true) !== null);
        } else if (action === 'due') {
            key(19, ['command down']); key(45, ['command down']);
            wait(function () { return find(null, 'task-due-enabled', true); }, 'DUE_TOGGLE');
            press(control(null, 'task-due-enabled', true));
            check('dueDateVisible', find(null, 'task-due-date', true) !== null);
            press(control(null, 'task-due-reminder-enabled', true));
            check('threeDaysDefault', find(null, '마감 3일 전부터') !== null);
            var stepper = control(null, 'task-due-reminder-days', true);
            need(Number($.AXUIElementPerformAction(stepper, $('AXIncrement'))) === 0, 'STEPPER_INCREMENT'); pause();
            check('fourDaysSelected', find(null, '마감 4일 전부터') !== null);
            press(control(null, 'task-due-enabled', true));
            check('reminderRemovedWithDueDate', find(null, 'task-due-reminder-enabled', true) === null);
            key(53);
        } else if (action === 'secret') {
            // Main navigation releases shared Secret editor ownership before the panel opens.
            key(18, ['command down']); key(45, ['command down']); key(20, ['command down']);
            var unlock = find('AXButton', '잠금 해제', true); if (unlock) press(unlock);
            var group = wait(function () { return find('AXTextField', '그룹 (선택 사항)', true); }, 'SECRET_GROUP');
            check('groupInitiallyFocused', focused(group));
            input(group, 'UI');
            check('groupCompletionVisible', wait(function () { return find(null, 'UI 검증 전용', true); }, 'GROUP_COMPLETION'));
            key(125); key(36);
            check('completionApplied', text(control('AXTextField', '그룹 (선택 사항)', true), 'AXValue') === 'UI 검증 전용');
            key(48);
            check('tabMovesToName', focused(control('AXTextField', 'Secret 제목', true)));
            key(53);
        } else if (action === 'reports') {
            var report = find(null, '리포트', true); if (report) press(report);
            else throw new Error('REPORT_NAV');
            press(wait(function () { return find(null, 'report-library-period-weekly', true); }, 'WEEKLY_FILTER'));
            check('weeklyAndPerformanceRows', find(null, '주간보고') !== null && find(null, '성과자료') !== null);
        } else throw new Error('UNKNOWN_ACTION');
        result.ok = true; result.stage = stage; return JSON.stringify(result);
    } catch (error) { result.stage = stage; result.error = String(error.message || error); throw new Error(JSON.stringify(result)); }
}
