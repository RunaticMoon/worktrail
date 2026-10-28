/* Native UI checks for a disposable DEBUG fixture only.
 * osascript -l JavaScript scripts/maclab/workflow-enhancements-check.js --pid PID --action inspect|settings|integrations|due|secret|secretLibrary|reports|windows|screenshot
 * Requires a /tmp/WorkLogUIReview- directory, dev.worklog.UIReview.Workflow013,
 * verified --ui-test-fixture many, and the exact PID.
 * Never launches OAuth, saves credentials, starts recording, or targets production.
 * Integration input uses synthetic values only and does not save or import.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

function read(node, attribute) {
    if (!node) return null;
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
    var result = {ok: false, checks: {}, realMicrophoneOpened: false, realCredentialsEntered: false, settingsSaved: false};
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
                    var values = [text(node, 'AXTitle'), text(node, 'AXDescription'), text(node, 'AXIdentifier'),
                        text(read(node, 'AXTitleUIElement'), 'AXValue'), text(node, 'AXPlaceholderValue')];
                    if (actualRole === 'AXStaticText') values.push(text(node, 'AXValue'));
                    return values.some(function (value) { return exact ? value === label : value.indexOf(label) >= 0; });
                });
                if (match) return match;
            }
            return null;
        }
        function control(role, label, exact) { return need(find(role, label, exact), 'MISSING_' + label); }
        function front() { return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid; }
        function inputAllowed() {
            var current = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary()));
            var locked = current.CGSSessionScreenIsLocked;
            if (!result.inputLockSamples) result.inputLockSamples = [];
            result.inputLockSamples.push({type: typeof locked, value: locked === undefined ? null : locked});
            need(locked === undefined || locked === false || locked === 0, 'SCREEN_LOCKED');
            need(Boolean(current.kCGSSessionOnConsoleKey) && Boolean(current.kCGSessionLoginDoneKey), 'CONSOLE_UNAVAILABLE');
            need(front(), 'FOREGROUND');
        }
        function press(node) { inputAllowed(); need(Number($.AXUIElementPerformAction(node, $('AXPress'))) === 0, 'PRESS'); pause(); }
        function key(code, modifiers) { inputAllowed(); events.keyCode(code, {using: modifiers || []}); pause(); }
        function capture(label) {
            inputAllowed();
            var info = array(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
            var owned = info.filter(function (item) {
                var bounds = ObjC.deepUnwrap(item.objectForKey('kCGWindowBounds'));
                return Number(ObjC.unwrap(item.objectForKey('kCGWindowOwnerPID'))) === pid &&
                    bounds.Width >= 300 && bounds.Height >= 200;
            });
            if (!owned.length) { result.screenshotUnavailable = true; return; }
            var id = Number(ObjC.unwrap(owned[0].objectForKey('kCGWindowNumber')));
            need(Number.isInteger(id) && id > 0, 'SCREENSHOT_WINDOW_ID');
            var destination = path.replace(/\/[^/]+\.app$/, '') + '/' + label + '.png';
            try {
                automation.doShellScript('/usr/sbin/screencapture -x -o -l ' + id + " '" + destination.replace(/'/g, "'\\''") + "'");
                if (!result.screenshots) result.screenshots = [];
                result.screenshots.push(destination);
            } catch (_) { result.screenshotUnavailable = true; }
        }
        function focused(node) { var value = read(node, 'AXFocused'); return value !== null && Boolean(ObjC.unwrap(value)); }
        function focus(node) { inputAllowed(); need(Number($.AXUIElementSetAttributeValue(node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'FOCUS'); pause(); }
        function input(node, value) {
            focus(node); key(0, ['command down']);
            need(/^[\x20-\x7E]*$/.test(value), 'SYNTHETIC_ASCII_INPUT');
            inputAllowed(); events.keystroke(value); pause();
        }
        function clickNode(node) {
            function coordinate(attribute, component) {
                var native = need(read(node, attribute), 'BOUNDS_MISSING');
                var description = string(ObjC.castRefToObject($.CFCopyDescription(native)));
                var names = component === 'width' ? '(?:width|w)' : component === 'height' ? '(?:height|h)' : component;
                var match = description.match(new RegExp('\\b' + names + '\\s*[:=]\\s*(-?[0-9]+(?:\\.[0-9]+)?)'));
                return Number(need(match, 'BOUNDS_UNREADABLE')[1]);
            }
            var x = coordinate('AXPosition', 'x'), y = coordinate('AXPosition', 'y');
            var width = coordinate('AXSize', 'width'), height = coordinate('AXSize', 'height');
            need(width > 0 && height > 0, 'BOUNDS_EMPTY');
            inputAllowed();
            var point = $.CGPointMake(x + width / 2, y + height / 2);
            var down = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft);
            var up = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft);
            $.CGEventSetIntegerValueField(down, $.kCGMouseEventClickState, 1);
            $.CGEventSetIntegerValueField(up, $.kCGMouseEventClickState, 1);
            $.CGEventPost($.kCGHIDEventTap, down);
            $.CGEventPost($.kCGHIDEventTap, up);
            pause();
        }
        function selectSettingsRow(label) {
            var button = find('AXButton', label, true);
            if (button) { press(button); return; }
            clickNode(wait(function () { return find('AXStaticText', label, true); }, 'SETTINGS_ROW_' + label));
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
            if (main) {
                $.AXUIElementPerformAction(main, $('AXRaise'));
                $.AXUIElementSetAttributeValue(main, $('AXMain'), $.kCFBooleanTrue);
                $.AXUIElementSetAttributeValue(main, $('AXFocused'), $.kCFBooleanTrue);
            }
            wait(front, 'ACTIVATE');
        }
        if (action !== 'inspect' && action !== 'windows') activate();
        if (['settings', 'integrations', 'due', 'secret', 'reports', 'secretLibrary'].indexOf(action) >= 0) {
            var existingPanelClose = find('AXButton', '빠른 입력 닫기', true);
            if (existingPanelClose) press(existingPanelClose);
        }
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
        } else if (action === 'screenshot') {
            capture('workflow-current');
        } else if (action === 'windows') {
            ObjC.import('CoreGraphics');
            var info = array(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
            result.windows = info.filter(function (item) { return Number(ObjC.unwrap(item.objectForKey('kCGWindowOwnerPID'))) === pid; }).map(function (item) {
                return {id: Number(ObjC.unwrap(item.objectForKey('kCGWindowNumber'))), layer: Number(ObjC.unwrap(item.objectForKey('kCGWindowLayer')))};
            });
        } else if (action === 'settings') {
            key(43, ['command down']);
            selectSettingsRow('AI 연결');
            if (!find('AXTextField', 'Codex CLI 실행 파일')) {
                press(control('AXPopUpButton', 'AI 연결 방식'));
                press(wait(function () { return find('AXMenuItem', 'Codex CLI', false); }, 'CLI_OPTION'));
            }
            check('cliPathField', wait(function () { return find('AXTextField', 'Codex CLI 실행 파일'); }, 'CLI_PATH_FIELD') !== null);
            var picker = control('AXPopUpButton', 'AI 연결 방식'); press(picker);
            press(wait(function () { return find('AXMenuItem', 'OpenAI 호환 API', false); }, 'COMPATIBLE_OPTION'));
            check('compatibleBaseURL', wait(function () { return find('AXTextField', 'API 기본 URL'); }, 'COMPATIBLE_BASE_URL') !== null);
            check('deepSeekPreset', find('AXButton', 'DeepSeek 기본값 사용', true) !== null);
            press(control('AXButton', 'DeepSeek 기본값 사용', true));
            check('deepSeekURL', text(control('AXTextField', 'API 기본 URL'), 'AXValue') === 'https://api.deepseek.com');
            capture('compatible-settings');
            press(control('AXPopUpButton', 'AI 연결 방식'));
            press(wait(function () { return find('AXMenuItem', 'Codex CLI', false); }, 'CLI_OPTION'));
        } else if (action === 'integrations') {
            key(43, ['command down']);
            selectSettingsRow('활동 수집');
            var fields = [
                {id: 'activity-github-base-url', value: 'https://github.example.invalid'},
                {id: 'activity-github-account', value: 'fixture-user'},
                {id: 'activity-github-token', value: 'fixturegithubtoken', secure: true},
                {id: 'activity-jira-base-url', value: 'https://jira.example.invalid'},
                {id: 'activity-jira-account', value: 'fixture@example.invalid'},
                {id: 'activity-jira-token', value: 'fixturejiratoken', secure: true},
                {id: 'activity-jira-jql', value: 'assignee = currentUser()'}
            ];
            fields.forEach(function (field) {
                var node = wait(function () { return find(null, field.id, true); }, 'FIELD_' + field.id);
                check(field.id + '-visible', node !== null && Boolean(ObjC.unwrap(read(node, 'AXEnabled'))));
                if (field.secure) check(field.id + '-secure', text(node, 'AXSubrole') === 'AXSecureTextField');
            });
            capture('activity-integrations');
            fields.forEach(function (field) {
                input(control(null, field.id, true), field.value);
                check(field.id + '-editable', wait(function () {
                    var current = control(null, field.id, true);
                    var value = text(current, 'AXValue');
                    return field.secure ? value.length > 0 : value === field.value;
                }, 'INPUT_' + field.id));
            });
            result.syntheticCredentialsEntered = true;
            check('manualImport', find('AXButton', '지금 가져오기', true) !== null);
            capture('activity-integrations-input');
        } else if (action === 'due') {
            key(19, ['command down']); key(45, ['command down']);
            wait(function () { return find(null, 'task-due-enabled', true); }, 'DUE_TOGGLE');
            press(control(null, 'task-due-enabled', true));
            check('dueDateVisible', find(null, 'task-due-date', true) !== null);
            press(control(null, 'task-due-reminder-enabled', true));
            check('threeDaysDefault', find(null, '마감 3일 전부터') !== null);
            var stepper = control(null, 'task-due-reminder-days', true);
            inputAllowed();
            need(Number($.AXUIElementPerformAction(stepper, $('AXIncrement'))) === 0, 'STEPPER_INCREMENT'); pause();
            check('fourDaysSelected', find(null, '마감 4일 전부터') !== null);
            capture('task-due-four-days');
            press(control(null, 'task-due-enabled', true));
            check('reminderRemovedWithDueDate', find(null, 'task-due-reminder-enabled', true) === null);
            key(53);
        } else if (action === 'secret') {
            // Main navigation releases shared Secret editor ownership before the panel opens.
            key(18, ['command down']); key(45, ['command down']); key(20, ['command down']);
            var unlock = find('AXButton', '잠금 해제', true); if (unlock) press(unlock);
            var resume = find('AXButton', '이어서 편집', true); if (resume) press(resume);
            var group = wait(function () { return find('AXTextField', '그룹 (선택 사항)', true); }, 'SECRET_GROUP');
            check('groupInitiallyFocused', focused(group));
            input(group, 'UI');
            check('groupCompletionVisible', wait(function () { return find(null, 'UI 검증 전용', true); }, 'GROUP_COMPLETION'));
            capture('secret-group-completion');
            key(125); key(36);
            check('completionApplied', text(control('AXTextField', '그룹 (선택 사항)', true), 'AXValue') === 'UI 검증 전용');
            key(48);
            check('tabMovesToName', focused(control('AXTextField', 'Secret 제목', true)));
            capture('secret-name-focus');
            key(53);
        } else if (action === 'secretLibrary') {
            key(26, ['command down']); // Command-7: Secret library.
            var unlockLibrary = find('AXButton', '잠금 해제', true); if (unlockLibrary) press(unlockLibrary);
            check('secretGroupSection', wait(function () { return find(null, 'UI 검증 전용'); }, 'SECRET_GROUP_SECTION') !== null);
            capture('secret-group-library');
        } else if (action === 'reports') {
            key(22, ['command down']); // Command-6: report library.
            press(wait(function () { return find(null, 'report-library-period-weekly', true); }, 'WEEKLY_FILTER'));
            check('weeklyAndPerformanceRows', find(null, '주간보고') !== null && find(null, '성과자료') !== null);
            capture('report-family-icons');
        } else throw new Error('UNKNOWN_ACTION');
        result.ok = true; result.stage = stage; return JSON.stringify(result);
    } catch (error) { result.stage = stage; result.error = String(error.message || error); throw new Error(JSON.stringify(result)); }
}
