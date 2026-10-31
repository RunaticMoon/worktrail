/* Actual OS notification clicks against a disposable DEBUG fixture only.
 * Launch TaskNavigationReview.app with --ui-test-fixture many
 *   --ui-test-task-notification cancel|discard|same, then immediately run:
 * osascript -l JavaScript scripts/maclab/task-notification-navigation-check.js \
 *   --pid PID --action cancel|discard|same
 * Each action requires a fresh launch; the synthetic notification arrives 20s
 * after authorization. No production app, real records, clipboard or credentials.
 * OS mode requires the bundle outside temp dirs: copy it with ditto to
 * ~/.local/state/worktrail-issue-52-review/ and only ever launch it with the
 * fixture arguments above (open -n ... --args ...). Never launch the review bundle
 * without --ui-test-fixture: a DEBUG build without it opens the standard user
 * storage and Keychain. A /tmp bundle is marked in-temp-dir by LaunchServices and
 * usernoted then rejects it, so copy instead of running from /tmp.
 * If the OS rejects review-app notifications, explicitly launch with
 * --ui-test-task-notification-dispatch callback and pass --dispatch callback here;
 * callback mode keeps using /tmp/worktrail-issue-52-review.
 * That path verifies the production navigation callback, not an OS notification click.
 * NotificationCenter queries use exact synthetic-text predicates; unrelated
 * notification text is never fetched, printed, clicked or dismissed.
 * The caller wakes the display and handles the first review-app authorization.
 * node --check is syntax validation, not a successful macOS UI test.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

function navigationRead(node, attribute) {
    if (!node) return null;
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function navigationString(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value); return typeof result === 'string' ? result : '';
}
function navigationText(node, attribute) { return navigationString(navigationRead(node, attribute)); }
function navigationArray(value) {
    if (value === null || value === undefined) return [];
    var values = [], count = Number(value.count);
    for (var index = 0; index < count; index++) values.push(value.objectAtIndex(index));
    return values;
}

function run(args) {
    var started = Number($.NSProcessInfo.processInfo.systemUptime), stage = 'fixture_guard';
    var result = {ok: false, checks: {}, actualNotificationClicked: false, callbackInvoked: false, realDataRead: false};
    var pid, app, ax, events, action, usesCallback;
    var taskA = '여러 프로젝트에 함께 적용하는 배포 파이프라인 개선과 긴 한국어 업무명 표시·줄바꿈 검증';
    var taskB = '검색 결과에서 원문을 확인하고 입력하던 검색 조건으로 돌아오는 흐름 점검';
    var activity = 'WorkLog issue 52 synthetic activity for task A';
    var checklist = 'WorkLog issue 52 synthetic checklist for task A';
    var reason = 'WorkLog issue 52 synthetic reason for task A';
    function need(value, code) { if (!value) throw new Error(code); return value; }
    function check(name, value) { result.checks[name] = Boolean(value); need(value, 'ASSERT_' + name); }
    function tick() { need(Number($.NSProcessInfo.processInfo.systemUptime) - started < 85, 'DEADLINE'); }
    function pause() { tick(); delay(0.15); }
    function waitFor(read, code, seconds) {
        var until = Number($.NSProcessInfo.processInfo.systemUptime) + (seconds || 7);
        do { tick(); var value = read(); if (value) return value; pause(); }
        while (Number($.NSProcessInfo.processInfo.systemUptime) < until);
        throw new Error(code);
    }
    function front() { return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid; }
    function windows() { return navigationArray(navigationRead(ax, 'AXWindows')); }
    function detailRoots() {
        var queue = windows(), roots = [], visited = 0;
        while (queue.length && visited++ < 1800) {
            tick(); var node = queue.shift();
            if (navigationText(node, 'AXRole') === 'AXSheet') { roots.push(node); continue; }
            var attached = navigationArray(navigationRead(node, 'AXSheets'));
            if (attached.length) { roots = roots.concat(attached); continue; }
            navigationArray(navigationRead(node, 'AXChildren')).forEach(function (child) { queue.push(child); });
        }
        need(queue.length === 0, 'FIXTURE_SHEET_TRAVERSAL_LIMIT'); return roots;
    }
    function find(role, label) {
        // Task names may also appear in the main list. Assertions and controls
        // must belong to the presented detail/confirmation sheets.
        var queue = detailRoots(), visited = 0;
        while (queue.length && visited++ < 2200) {
            tick(); var node = queue.shift(), actualRole = navigationText(node, 'AXRole');
            if (!role || role === actualRole) {
                var values = ['AXTitle', 'AXDescription', 'AXIdentifier', 'AXPlaceholderValue'].map(function (attribute) {
                    return navigationText(node, attribute);
                });
                if (actualRole === 'AXStaticText') values.push(navigationText(node, 'AXValue'));
                if (values.indexOf(label) >= 0) return node;
            }
            navigationArray(navigationRead(node, 'AXChildren')).forEach(function (child) { queue.push(child); });
        }
        need(queue.length === 0, 'FIXTURE_AX_TRAVERSAL_LIMIT'); return null;
    }
    function key(code, modifiers) {
        need(front(), 'FIXTURE_NOT_FOREGROUND'); events.keyCode(code, {using: modifiers || []}); pause();
    }
    function clickButton(node) {
        need(front(), 'FIXTURE_NOT_FOREGROUND');
        need(node, 'BUTTON_MISSING');
        function coordinate(attribute, component) {
            var value = need(navigationRead(node, attribute), 'BUTTON_BOUNDS_MISSING');
            var description = navigationString(ObjC.castRefToObject($.CFCopyDescription(value)));
            var names = component === 'width' ? '(?:width|w)' : component === 'height' ? '(?:height|h)' : component;
            var match = description.match(new RegExp('\\b' + names + '\\s*[:=]\\s*(-?[0-9]+(?:\\.[0-9]+)?)'));
            return Number(need(match, 'BUTTON_BOUNDS_UNREADABLE')[1]);
        }
        var x = coordinate('AXPosition', 'x'), y = coordinate('AXPosition', 'y');
        var width = coordinate('AXSize', 'width'), height = coordinate('AXSize', 'height');
        need(width > 0 && height > 0, 'BUTTON_BOUNDS_EMPTY');
        var point = $.CGPointMake(x + width / 2, y + height / 2);
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
        pause();
    }
    function checklistField() { return find('AXTextField', 'task-detail-checklist-input'); }
    function showChecklist() {
        key(38, ['command down', 'shift down']);
        return waitFor(checklistField, 'CHECKLIST_FIELD_MISSING');
    }
    function snapshot() {
        var editor = need(find('AXTextArea', '진행 기록 내용'), 'ACTIVITY_EDITOR_MISSING');
        var field = need(checklistField(), 'CHECKLIST_FIELD_MISSING');
        var scope = need(find('AXPopUpButton', '진행 기록 범위'), 'SCOPE_PICKER_MISSING');
        return {
            taskA: Boolean(find(null, taskA)),
            activity: navigationText(editor, 'AXValue'), checklist: navigationText(field, 'AXValue'),
            scope: navigationText(scope, 'AXValue'),
            date: Boolean(find('AXStaticText', '2026-10-09 업무일로 저장')),
            reason: navigationText(find('AXTextField', '상태 변경 사유'), 'AXValue')
        };
    }
    function checkPreserved(prefix, before) {
        var after = snapshot();
        check(prefix + 'TaskA', after.taskA);
        check(prefix + 'Activity', after.activity === before.activity);
        check(prefix + 'Checklist', after.checklist === before.checklist);
        check(prefix + 'Date', after.date);
        check(prefix + 'ProjectScope', after.scope === before.scope && after.scope.indexOf('공통 플랫폼') >= 0);
        check(prefix + 'StatusReason', after.reason === before.reason);
    }
    function exactNotification(title) {
        // Query the system process using an exact predicate. Retrieve only UI
        // references for traversal and bounds for the matching synthetic title;
        // never fetch a list of other apps' notification titles or contents.
        var notificationProcess = events.processes.byName('NotificationCenter');
        if (!notificationProcess.exists()) return null;
        var queue = notificationProcess.windows(), visited = 0;
        while (queue.length && visited++ < 800) {
            tick(); var node = queue.shift(), matches = [];
            try { matches = node.staticTexts.whose({value: title})(); } catch (_) {}
            if (matches.length === 1) return matches[0];
            need(matches.length < 2, 'AMBIGUOUS_FIXTURE_NOTIFICATION');
            try { node.uiElements().forEach(function (child) { queue.push(child); }); } catch (_) {}
        }
        need(queue.length === 0, 'NOTIFICATION_REFERENCE_TRAVERSAL_LIMIT'); return null;
    }
    function clickNotification(marker) {
        var position = marker.position(), size = marker.size();
        need(position.length === 2 && size.length === 2 && size[0] > 0 && size[1] > 0, 'NOTIFICATION_BOUNDS_MISSING');
        var point = $.CGPointMake(position[0] + size[0] / 2, position[1] + size[1] / 2);
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
        result.actualNotificationClicked = true;
        waitFor(front, 'NOTIFICATION_DID_NOT_ACTIVATE_FIXTURE');
    }
    try {
        need((args.length === 4 || args.length === 6) && args[0] === '--pid' && args[2] === '--action', 'ARGUMENTS');
        usesCallback = args.length === 6;
        need(!usesCallback || (args[4] === '--dispatch' && args[5] === 'callback'), 'DISPATCH_ARGUMENT');
        pid = Number(args[1]); action = args[3]; result.action = action;
        need(Number.isInteger(pid) && pid > 1 && ['cancel', 'discard', 'same'].indexOf(action) >= 0, 'ARGUMENTS');
        app = need($.NSRunningApplication.runningApplicationWithProcessIdentifier(pid), 'FIXTURE_NOT_RUNNING');
        need(navigationString(app.bundleIdentifier) === 'dev.worklog.TaskNavigationReview', 'FIXTURE_BUNDLE');
        // Callback fixtures must stay under /tmp (UITestFixture.swift only allows
        // that). OS notifications need a bundle outside temp dirs, because
        // LaunchServices marks /tmp bundles in-temp-dir and usernoted rejects them.
        var bundlePath = navigationString(app.bundleURL.path);
        if (usesCallback) {
            need(/^\/(?:private\/)?tmp\/worktrail-issue-52-review\/TaskNavigationReview\.app$/.test(bundlePath), 'FIXTURE_PATH');
        } else {
            var reviewHome = navigationString($.NSHomeDirectory());
            need(bundlePath === reviewHome + '/.local/state/worktrail-issue-52-review/TaskNavigationReview.app', 'FIXTURE_PATH');
        }
        var automation = Application.currentApplication(); automation.includeStandardAdditions = true;
        var command = automation.doShellScript('/bin/ps -ww -p ' + pid + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+many(?:\s|$)/.test(command), 'FIXTURE_ARGUMENT');
        need(new RegExp('(?:^|\\s)--ui-test-task-notification\\s+' + action + '(?:\\s|$)').test(command), 'NOTIFICATION_ARGUMENT');
        need((command.match(/--ui-test-fixture/g) || []).length === 1 &&
            (command.match(/--ui-test-task-notification(?:\s|$)/g) || []).length === 1, 'AMBIGUOUS_ARGUMENTS');
        check('dispatchModeMatchesLaunch', usesCallback
            ? /(?:^|\s)--ui-test-task-notification-dispatch\s+callback(?:\s|$)/.test(command)
            : command.indexOf('--ui-test-task-notification-dispatch') < 0);
        command = null; check('isolatedSyntheticFixture', true);
        var session = ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary()));
        need(session.kCGSSessionOnConsoleKey && session.kCGSessionLoginDoneKey && !session.CGSSessionScreenIsLocked, 'CONSOLE_UNAVAILABLE');
        need(Boolean($.AXIsProcessTrusted()), 'ACCESSIBILITY_UNAVAILABLE');
        ax = $.AXUIElementCreateApplication(pid); $.AXUIElementSetMessagingTimeout(ax, 0.5);
        events = Application('System Events');
        app.activateWithOptions(3); waitFor(front, 'FIXTURE_NOT_ACTIVE');
        waitFor(function () { return find(null, taskA); }, 'INITIAL_TASK_A_MISSING');
        showChecklist();
        var before = snapshot();
        check('initialDraftsBelongToA', before.taskA && before.activity === activity && before.checklist === checklist);
        check('initialDateAndScope', before.date && before.scope.indexOf('공통 플랫폼') >= 0);
        check('initialStatusReason', before.reason === reason);

        if (usesCallback) {
            stage = 'synthetic_callback';
            waitFor(function () {
                var data = $.NSData.dataWithContentsOfFile($('/tmp/worktrail-issue-52-review/notification-callback-' + pid + '.json'));
                if (!data) return false;
                var evidence = JSON.parse(navigationString($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
                return evidence.callbackInvoked === true && evidence.mode === action && evidence.target === (action === 'same' ? 'A' : 'B');
            }, 'SYNTHETIC_CALLBACK_NOT_INVOKED', 20);
            result.callbackInvoked = true;
        } else {
            stage = 'notification_click';
            var marker = waitFor(function () { return exactNotification('WorkLog issue 52 ' + action + ' fixture'); },
                'SYNTHETIC_NOTIFICATION_NOT_VISIBLE', 35);
            clickNotification(marker);
        }
        if (action === 'cancel' || action === 'discard') {
            stage = 'navigation_confirmation';
            waitFor(function () { return find('AXStaticText', '다른 업무로 이동할까요?'); }, 'CONFIRMATION_MISSING');
            check('requiresNavigationDecision', true);
            if (action === 'cancel') {
                need(find('AXButton', '계속 편집'), 'CANCEL_BUTTON_MISSING'); key(53);
                waitFor(function () { return !find('AXButton', '입력 버리고 이동'); }, 'CONFIRMATION_NOT_DISMISSED');
                checkPreserved('cancelKeeps', before);
            } else {
                clickButton(find('AXButton', '입력 버리고 이동'));
                waitFor(function () { return find(null, taskB); }, 'TASK_B_NOT_OPENED');
                showChecklist();
                var bEditor = need(find('AXTextArea', '진행 기록 내용'), 'B_ACTIVITY_EDITOR_MISSING');
                var bChecklist = need(checklistField(), 'B_CHECKLIST_FIELD_MISSING');
                var saveButton = need(find('AXButton', '진행 기록 저장'), 'B_SAVE_BUTTON_MISSING');
                var addButton = need(find('AXButton', 'task-detail-checklist-add'), 'B_ADD_BUTTON_MISSING');
                check('discardOpensB', Boolean(find(null, taskB)));
                check('bActivityEmpty', navigationText(bEditor, 'AXValue') === '');
                check('bChecklistEmpty', navigationText(bChecklist, 'AXValue') === '');
                check('bHasNoActivityFromA', !find('AXStaticText', activity));
                check('bHasNoChecklistFromA', !find('AXCheckBox', checklist));
                check('emptyActivityCannotSave', ObjC.unwrap(need(navigationRead(saveButton, 'AXEnabled'), 'B_SAVE_ENABLED_MISSING')) === false);
                check('emptyChecklistCannotAdd', ObjC.unwrap(need(navigationRead(addButton, 'AXEnabled'), 'B_ADD_ENABLED_MISSING')) === false);
            }
        } else {
            stage = 'same_task';
            delay(0.5);
            check('sameTaskNeedsNoConfirmation', !find('AXButton', '입력 버리고 이동'));
            checkPreserved('sameTaskKeeps', before);
            key(36, ['command down']);
            waitFor(function () { return navigationText(find('AXTextArea', '진행 기록 내용'), 'AXValue') === ''; }, 'ACTIVITY_NOT_SAVED');
            check('activitySavedUnderA', Boolean(find(null, taskA)) && Boolean(find('AXStaticText', activity)));
            check('activitySaveKeepsChecklistDraft', navigationText(checklistField(), 'AXValue') === checklist);
            showChecklist(); key(36);
            waitFor(function () { return navigationText(checklistField(), 'AXValue') === ''; }, 'CHECKLIST_NOT_ADDED');
            check('checklistSavedUnderA', Boolean(find(null, taskA)) && Boolean(find('AXCheckBox', checklist)));
        }
        result.ok = true; result.stage = 'complete'; return JSON.stringify(result);
    } catch (error) {
        result.stage = stage;
        // Return only this script's fixed error codes, never AX text or system errors.
        result.error = /^[A-Z][A-Za-z0-9_]*$/.test(error.message || '') ? error.message : 'UI_AUTOMATION_FAILED';
        console.log(JSON.stringify(result)); throw new Error(result.error);
    }
}
