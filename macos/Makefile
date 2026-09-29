.PHONY: native test-native trials
SIGN_IDENTITY ?= -
FLAGS = -Wall -Wextra -Werror -fobjc-arc -framework AppKit -framework ApplicationServices -framework Security -framework IOKit -lbsm -lproc
CORE = native/WindowSpace.m native/Shield.m native/Runtime.m native/Controller.c native/Attempt.c
HEADERS = native/WindowSpace.h native/Shield.h native/Runtime.h native/Controller.h native/Attempt.h
APP = build/MacLock.app
PLUGIN = build/MacLockAuthorization.bundle

native: $(APP)/Contents/MacOS/mac-lock $(PLUGIN)/Contents/MacOS/MacLockAuthorization

$(APP)/Contents/MacOS/mac-lock: native/Native.m native/Startup.m native/Startup.h native/DisplayWake.m native/DisplayWake.h $(CORE) $(HEADERS) native/App-Info.plist native/SkyLightWindow-LICENSE.txt
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp native/App-Info.plist $(APP)/Contents/Info.plist
	cp native/SkyLightWindow-LICENSE.txt $(APP)/Contents/Resources/
	xcrun clang $(FLAGS) native/Native.m native/Startup.m native/DisplayWake.m $(CORE) -o $@
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime --timestamp=none $(APP)
	codesign --verify --strict $(APP)

$(PLUGIN)/Contents/MacOS/MacLockAuthorization: native/Authorization.m native/Runtime.m native/Runtime.h native/Controller.h native/Authorization-Info.plist
	mkdir -p $(PLUGIN)/Contents/MacOS
	cp native/Authorization-Info.plist $(PLUGIN)/Contents/Info.plist
	xcrun clang $(FLAGS) -bundle native/Authorization.m native/Runtime.m -o $@
	codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none $(PLUGIN)
	codesign --verify --strict $(PLUGIN)

trials: build/mac-lock-trials
build/mac-lock-trials: native/GuardianTrial.m $(CORE) $(HEADERS)
	mkdir -p build
	xcrun clang $(FLAGS) native/GuardianTrial.m $(CORE) -o $@
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier br.com.alexandrem.mac-lock.trials --timestamp=none $@

build/controller-fixture: native/controller-fixture.c
	mkdir -p build
	xcrun clang -Wall -Wextra -Werror -std=c11 $< -o $@
	codesign --force --sign - --identifier br.com.alexandrem.mac-lock.controller-fixture $@

build/controller-contract: native/Controller.c native/Controller.h native/test-controller.c build/controller-fixture
	xcrun clang -Wall -Wextra -Werror -std=c11 -framework Security -framework CoreFoundation -lbsm -lproc native/Controller.c native/test-controller.c -o $@

build/attempt-contract: native/Attempt.c native/Attempt.h native/test-attempt.c
	mkdir -p build
	xcrun clang -Wall -Wextra -Werror native/Attempt.c native/test-attempt.c -o $@

build/plugin-contract: native/test-plugin.c
	mkdir -p build
	xcrun clang -Wall -Wextra -Werror -std=c11 -framework Security $< -o $@

build/authorization-contract: native/Authorization.m native/Attempt.c native/Attempt.h native/Runtime.h native/test-authorization.m
	mkdir -p build
	xcrun clang $(FLAGS) native/Authorization.m native/Attempt.c native/test-authorization.m -o $@

build/lock-state-contract: native/Runtime.m native/Runtime.h native/Controller.h native/test-lock-state.m
	mkdir -p build
	xcrun clang $(FLAGS) native/Runtime.m native/test-lock-state.m -o $@

build/source-contract: native/Shield.m native/WindowSpace.m native/Attempt.c $(HEADERS) native/test-source.m
	mkdir -p build
	xcrun clang $(FLAGS) native/Shield.m native/WindowSpace.m native/Attempt.c native/test-source.m -o $@

build/login-ui-contract: native/Runtime.m native/Runtime.h native/Controller.h native/test-login-ui.m
	mkdir -p build
	xcrun clang $(FLAGS) -Dnotify_register_check=fixture_notify_register_check -Dnotify_get_state=fixture_notify_get_state -Dnotify_cancel=fixture_notify_cancel native/Runtime.m native/test-login-ui.m -o $@

build/window-space-contract: native/WindowSpace.m native/WindowSpace.h native/test-window-space.m
	mkdir -p build
	xcrun clang $(FLAGS) -Ddlopen=fixture_dlopen -Ddlsym=fixture_dlsym -Ddlclose=fixture_dlclose native/WindowSpace.m native/test-window-space.m -o $@

build/startup-fixture: native/startup-fixture.m native/Startup.m native/Startup.h native/Runtime.m native/Runtime.h
	mkdir -p build
	xcrun clang $(FLAGS) native/startup-fixture.m native/Startup.m native/Runtime.m -o $@
	codesign --force --sign - --identifier br.com.alexandrem.mac-lock.startup-fixture $@

build/display-wake-contract: native/DisplayWake.m native/DisplayWake.h native/Runtime.h native/Controller.h native/test-display-wake.m
	mkdir -p build
	xcrun clang $(FLAGS) -DIOPMAssertionCreateWithName=fixture_create -DIOPMAssertionDeclareUserActivity=fixture_activity -DIOPMAssertionRelease=fixture_release -Dusleep=fixture_sleep native/DisplayWake.m native/test-display-wake.m -o $@

test-native: native build/controller-contract build/attempt-contract build/plugin-contract build/authorization-contract build/lock-state-contract build/source-contract build/login-ui-contract build/window-space-contract build/startup-fixture build/display-wake-contract
	./build/controller-contract
	./build/attempt-contract
	./build/plugin-contract $(PLUGIN)/Contents/MacOS/MacLockAuthorization operation
	./build/authorization-contract
	./build/lock-state-contract
	./build/source-contract
	./build/login-ui-contract
	./build/window-space-contract
	./build/display-wake-contract
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s native -p 'test_*.py' -v
