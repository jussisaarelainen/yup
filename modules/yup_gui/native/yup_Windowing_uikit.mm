/*
  ==============================================================================

   This file is part of the YUP library.
   Copyright (c) 2026 - kunitoki@gmail.com

   YUP is an open source library subject to open-source licensing.

   The code included in this file is provided under the terms of the ISC license
   http://www.isc.org/downloads/software-support-policy/isc-license. Permission
   to use, copy, modify, and/or distribute this software for any purpose with or
   without fee is hereby granted provided that the above copyright notice and
   this permission notice appear in all copies.

   YUP IS PROVIDED "AS IS" WITHOUT ANY WARRANTY, AND ALL WARRANTIES, WHETHER
   EXPRESSED OR IMPLIED, INCLUDING MERCHANTABILITY AND FITNESS FOR PURPOSE, ARE
   DISCLAIMED.

  ==============================================================================
*/

/** A component embedded in a host provided UIView on iOS (a plugin editor in an AUv3 app extension, or in the app
    that hosts it), without an SDL window: SDL's UIKit backend owns the application's UIWindow, which an app extension
    doesn't have. The component draws into a UIView of its own, added to the host's, with the Metal graphics context
    (a CAMetalLayer in that view), on the main thread at the display's refresh (CADisplayLink); the view's touches are
    its mouse events (the first finger: down, drag, up, double click; held still for longPressMs, the press becomes a
    right click, as iOS opens a context menu: the left press is cancelled, then the right button goes down and up). Text input is the on-screen keyboard: the view
    is the first responder while a TextInputTarget takes text (startTextInput), its typed text goes to that component
    and Delete and Return to the focused one as Backspace and Enter. Popup menus open inside the editor (PopupMenu:
    no windows of their own on iOS). ComponentNative::createFor makes one on iOS when it's given a parent.
*/

namespace yup
{
class UIKitComponentNative;
} // namespace yup

@interface YupUIKitComponentView : UIView <UIKeyInput>
@property (nonatomic, assign) yup::UIKitComponentNative* owner;
@property (nonatomic, assign) BOOL acceptsText;
@end

@interface YupUIKitDisplayLinkTarget : NSObject
@property (nonatomic, assign) yup::UIKitComponentNative* owner;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

namespace yup
{

class UIKitComponentNative final : public ComponentNative
{
public:
    UIKitComponentNative (Component& component, const Options& options, void* parent)
        : ComponentNative (component, options.flags)
        , clearColor (options.clearColor.value_or (Colors::black))
        , doubleClickTime (options.doubleClickTime.value_or (RelativeTime::milliseconds (200)))
        , repaintMode (options.repaintMode)
        , shouldRenderContinuous (options.flags.test (renderContinuous))
        , screenBounds (component.getBounds().to<int>())
    {
        // The reference createUIKitComponentNative's Ptr adopts (as SDLComponentNative's): without it a copy of the Ptr
        // (the long press's) would delete the native when it goes
        incReferenceCount();

        Desktop::getInstance()->registerNativeComponent (this);

        UIView* parentView = (__bridge UIView*) parent;

        view = [[YupUIKitComponentView alloc] initWithFrame:CGRectMake (0, 0, jmax (1, screenBounds.getWidth()), jmax (1, screenBounds.getHeight()))];
        view.owner = this;
        view.multipleTouchEnabled = NO;
        view.opaque = clearColor.isOpaque();
        view.backgroundColor = UIColor.clearColor;
        view.contentScaleFactor = parentView.window != nil ? parentView.window.screen.scale : UIScreen.mainScreen.scale;
        view.hidden = ! component.isVisible();
        [parentView addSubview:view];

        GraphicsContext::Options graphicsOptions;
        graphicsOptions.retinaDisplay = options.flags.test (allowHighDensityDisplay);
        graphicsOptions.vsync = true;

        context = GraphicsContext::createContext (GpuPlatform::Metal, graphicsOptions);

        if (context != nullptr)
        {
            const auto size = getContentSize();
            context->attachToWindow ((__bridge void*) view, size.getWidth(), size.getHeight(), getScaleDpi());
        }

        displayLinkTarget = [YupUIKitDisplayLinkTarget new];
        displayLinkTarget.owner = this;
        displayLink = [CADisplayLink displayLinkWithTarget:displayLinkTarget selector:@selector (onDisplayLink:)];
        [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

        lastRenderTimeSeconds = Time::getMillisecondCounterHiRes() / 1000.0;
        repaint();
    }

    ~UIKitComponentNative() override
    {
        [displayLink invalidate];
        displayLink = nil;
        displayLinkTarget.owner = nullptr;

        renderer.reset();

        if (context != nullptr)
            context->detachFromWindow();

        context.reset();

        view.owner = nullptr;
        [view removeFromSuperview];
        view = nil;

        Desktop::getInstance()->unregisterNativeComponent (this);
    }

    //==============================================================================

    void setTitle (const String& newTitle) override { title = newTitle; }
    String getTitle() const override { return title; }

    void setVisible (bool shouldBeVisible) override
    {
        view.hidden = ! shouldBeVisible;

        if (shouldBeVisible)
            repaint();
    }

    bool isVisible() const override { return view != nil && ! view.hidden; }

    bool isResizable() const override { return false; }
    void setResizable (bool) override {}

    void toFront() override { [view.superview bringSubviewToFront:view]; }

    //==============================================================================

    void setSize (const Size<int>& newSize) override
    {
        setBounds (screenBounds.withSize (newSize));
    }

    Size<int> getSize() const override { return screenBounds.getSize(); }

    Size<int> getContentSize() const override
    {
        const auto scale = getScaleDpi();
        return { jmax (1, roundToInt (static_cast<float> (screenBounds.getWidth()) * scale)),
                 jmax (1, roundToInt (static_cast<float> (screenBounds.getHeight()) * scale)) };
    }

    Point<int> getPosition() const override { return screenBounds.getPosition(); }

    void setPosition (const Point<int>& newPosition) override
    {
        setBounds (screenBounds.withPosition (newPosition));
    }

    Rectangle<int> getBounds() const override { return screenBounds; }

    void setBounds (const Rectangle<int>& newBounds) override
    {
        // Embedded: the view sits at the host view's origin, at the component's size
        const auto sizeChanged = newBounds.getSize() != screenBounds.getSize();
        screenBounds = newBounds;
        view.frame = CGRectMake (0, 0, jmax (1, newBounds.getWidth()), jmax (1, newBounds.getHeight()));

        if (sizeChanged)
        {
            component.internalResized (newBounds.getWidth(), newBounds.getHeight());
            repaint();
        }
    }

    Rectangle<int> getSafeAreaBounds() const override { return Rectangle<int> (0, 0, screenBounds.getWidth(), screenBounds.getHeight()); }

    void setFullScreen (bool) override {}
    bool isFullScreen() const override { return false; }
    bool isDecorated() const override { return false; }

    void setAspectRatio (std::optional<float> newAspectRatio) override { aspectRatio = newAspectRatio; }
    std::optional<float> getAspectRatio() const override { return aspectRatio; }

    void setOpacity (float newOpacity) override { view.alpha = newOpacity; }
    float getOpacity() const override { return view != nil ? static_cast<float> (view.alpha) : 1.0f; }

    //==============================================================================

    //! As SDLComponentNative's: the components hear their focus change (a TextEditor's focus starts its text input),
    //! and text input stops when the focus goes to a component that takes none
    void setFocusedComponent (Component* comp, FocusChangeType cause) override
    {
        if (focusedComponent == comp)
            return;

        auto compBailOut = Component::BailOutChecker (comp);
        WeakReference<Component> previous (focusedComponent.get());
        const bool previousWantsText = previous != nullptr && dynamic_cast<TextInputTarget*> (previous.get()) != nullptr;

        if (auto* old = previous.get())
        {
            auto focusBailOut = Component::BailOutChecker (old);
            old->internalFocusChanged (false);

            if (! focusBailOut.shouldBailOut())
                old->repaint();
        }

        if (compBailOut.shouldBailOut())
            comp = nullptr;

        focusedComponent = comp;

        if (previous != nullptr)
            previous->internalFocusOfComponentChanged (cause);

        const bool newWantsText = comp != nullptr && dynamic_cast<TextInputTarget*> (comp) != nullptr;

        if (previousWantsText && ! newWantsText && previous != nullptr)
            stopTextInput (*previous);

        if (auto* focused = focusedComponent.get())
        {
            auto focusBailOut = Component::BailOutChecker (focused);
            focused->internalFocusChanged (true);

            if (! focusBailOut.shouldBailOut())
            {
                focused->repaint();
                focused->internalFocusOfComponentChanged (cause);
            }
        }
    }
    Component* getFocusedComponent() const override { return focusedComponent.get(); }
    Component* getPointerTarget() const override { return clickedComponent.get(); }

    bool isContinuousRepaintingEnabled() const override { return shouldRenderContinuous; }
    void enableContinuousRepainting (bool shouldBeEnabled) override { shouldRenderContinuous = shouldBeEnabled; }
    bool isAtomicModeEnabled() const override { return renderAtomicMode; }
    void enableAtomicMode (bool shouldBeEnabled) override { renderAtomicMode = shouldBeEnabled; }
    bool isWireframeEnabled() const override { return renderWireframe; }
    void enableWireframe (bool shouldBeEnabled) override { renderWireframe = shouldBeEnabled; }
    GpuTriangulationThresholds getTriangulationThresholds() const override { return triangulationThresholds; }
    void setTriangulationThresholds (const GpuTriangulationThresholds& thresholds) override { triangulationThresholds = thresholds; }

    void repaint() override
    {
        currentRepaintAreas.clearQuick();
        currentRepaintAreas.add (Rectangle<float>().withSize (screenBounds.getSize().to<float>()));
    }

    void repaint (const Rectangle<float>& rect) override { currentRepaintAreas.add (rect); }
    const RectangleList<float>& getRepaintAreas() const override { return currentRepaintAreas; }

    void setGlobalMouseCaptureActive (bool) override {}

    void cancelCurrentMouseGesture() override
    {
        if (auto* clicked = clickedComponent.get())
            clicked->internalMouseUp (MouseEvent().withPosition (lastPosition).withSourceComponent (clicked).withRelativePositionTo (clicked));

        clickedComponent = nullptr;
    }

    // Text input: the on-screen keyboard while the view is the first responder
    void startTextInput (Component& textComponent) override
    {
        if (dynamic_cast<TextInputTarget*> (std::addressof (textComponent)) == nullptr)
            return;

        currentTextInputComponent = std::addressof (textComponent);
        view.acceptsText = YES;

        if (! view.isFirstResponder)
            [view becomeFirstResponder];
    }

    void stopTextInput (Component& textComponent) override
    {
        if (currentTextInputComponent.get() != std::addressof (textComponent))
            return;

        currentTextInputComponent = nullptr;
        view.acceptsText = NO;

        if (view.isFirstResponder)
            [view resignFirstResponder];
    }

    void updateTextInputRect (Component&) override {}

    void handleTextInput (const String& text)
    {
        if (auto* target = currentTextInputComponent.get())
            target->internalTextInput (text);
    }

    void handleKey (int keyCode)
    {
        auto* target = focusedComponent != nullptr ? focusedComponent.get() : std::addressof (component);
        const auto key = KeyPress (keyCode);
        auto bailOut = Component::BailOutChecker (target);

        target->internalKeyDown (key, lastPosition);

        if (! bailOut.shouldBailOut())
            target->internalKeyUp (key, lastPosition);
    }

    bool hasTextInput() const { return currentTextInputComponent != nullptr; }

    float getScaleDpi() const override
    {
        return view != nil ? static_cast<float> (view.contentScaleFactor) : 1.0f;
    }

    float getCurrentFrameRate() const override { return currentFrameRate; }
    float getDesiredFrameRate() const override { return 60.0f; }
    void setDesiredFrameRate (std::optional<float>) override {}
    bool isVsyncEnabled() const override { return true; }
    void setVsyncEnabled (bool) override {}

    void* getNativeHandle() const override { return (__bridge void*) view; }
    rive::Factory* getFactory() override { return context != nullptr ? context->getFactory() : nullptr; }
    GraphicsContext* getGraphicsContext() override { return context.get(); }

    //==============================================================================
    // From the view

    void viewDidLayout()
    {
        // The Metal layer follows the view (attachToWindow sets its frame once)
        for (CALayer* layer in view.layer.sublayers)
            if ([layer isKindOfClass:[CAMetalLayer class]])
                layer.frame = view.bounds;

        repaint();
    }

    void viewMovedToWindow()
    {
        if (view.window != nil && view.contentScaleFactor != view.window.screen.scale)
        {
            view.contentScaleFactor = view.window.screen.scale;
            currentContentWidth = currentContentHeight = 0; // the render target follows the new scale
        }

        repaint();
    }

    void handleTouch (UITouchPhase phase, CGPoint location)
    {
        const auto position = Point<float> (static_cast<float> (location.x), static_cast<float> (location.y));
        lastPosition = position;

        switch (phase)
        {
            case UITouchPhaseBegan:
                longPressRightClick = false;
                handleMouseDown (position);
                break;

            case UITouchPhaseMoved:
                if (! longPressRightClick)
                    handleMouseDrag (position);
                break;

            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                // A long press already ended as a right click
                ++currentPressId;

                if (! longPressRightClick)
                    handleMouseUp (position, phase == UITouchPhaseCancelled);

                longPressRightClick = false;
                break;

            default:
                break;
        }
    }

    void renderFrame()
    {
        // The component that took text went away without giving it up (an inline editor deleted): the keyboard goes
        if (currentTextInputComponent == nullptr && view.isFirstResponder)
        {
            view.acceptsText = NO;
            [view resignFirstResponder];
        }

        YUP_TRY
        {
            if (renderInternal())
            {
                context->end (getNativeHandle());
                context->tick();
            }
        }
        YUP_CATCH_EXCEPTION
    }

private:
    bool renderInternal()
    {
        if (context == nullptr || ! isVisible())
            return false;

        const auto contentSize = getContentSize();

        if (currentContentWidth != contentSize.getWidth() || currentContentHeight != contentSize.getHeight())
        {
            currentContentWidth = contentSize.getWidth();
            currentContentHeight = contentSize.getHeight();

            context->onSizeChanged (getNativeHandle(), currentContentWidth, currentContentHeight, getScaleDpi(), 0);
            renderer = context->makeRenderer (currentContentWidth, currentContentHeight);
            repaint();
        }

        const auto currentTimeSeconds = Time::getMillisecondCounterHiRes() / 1000.0;
        component.internalRefreshDisplay (currentTimeSeconds - lastRenderTimeSeconds);
        lastRenderTimeSeconds = currentTimeSeconds;

        if (shouldRenderContinuous)
            repaint();

        RectangleList<float> repaintAreas = std::move (currentRepaintAreas);
        currentRepaintAreas.clearQuick();

        if (repaintAreas.isEmpty() || renderer == nullptr)
            return false;

        // A drawable's previous contents aren't kept: the whole view is painted each frame
        rive::gpu::RenderContext::FrameDescriptor frameDescriptor;
        frameDescriptor.renderTargetWidth = static_cast<uint32_t> (currentContentWidth);
        frameDescriptor.renderTargetHeight = static_cast<uint32_t> (currentContentHeight);
        frameDescriptor.loadAction = rive::gpu::LoadAction::clear;
        frameDescriptor.clearColor = clearColor.getARGB();
        frameDescriptor.disableRasterOrdering = renderAtomicMode;
        frameDescriptor.wireframe = renderWireframe;
        frameDescriptor.triangulationThresholds.minArea = triangulationThresholds.minArea;
        frameDescriptor.triangulationThresholds.maxVerbs = triangulationThresholds.maxVerbs;
        frameDescriptor.triangulationThresholds.frameBudgetMs = triangulationThresholds.frameBudgetMs;

        context->begin (frameDescriptor);

        const auto localBounds = component.getLocalBounds();
        RectangleList<float> fullArea;
        fullArea.add (localBounds);
        frameRepaintAreas = fullArea;

        Graphics g (*context, *renderer, getScaleDpi());
        component.internalPaint (g, fullArea, shouldRenderContinuous);

        updateFrameRate (currentTimeSeconds);
        return true;
    }

    void updateFrameRate (double nowSeconds)
    {
        ++frameRateCounter;

        if (const auto elapsed = nowSeconds - frameRateStartTimeSeconds; elapsed >= 1.0)
        {
            currentFrameRate = static_cast<float> (frameRateCounter / elapsed);
            frameRateStartTimeSeconds = nowSeconds;
            frameRateCounter = 0;
        }
    }

    //==============================================================================

    MouseEvent makeEvent (const Point<float>& position, MouseEvent::Buttons buttons) const
    {
        return MouseEvent().withButtons (buttons).withPosition (position).withTouchIndex (0);
    }

    static constexpr int longPressMs = 500;
    static constexpr float longPressSlop = 8.0f;

    void handleMouseDown (const Point<float>& position)
    {
        // A press held still becomes a right click
        const auto pressId = ++currentPressId;
        longPressPosition = position;
        longPressMoved = false;

        // The native stays alive until the call (reference counted); its view gone, the press is over
        Timer::callAfterDelay (longPressMs, [keepAlive = ComponentNative::Ptr (this), self = this, pressId,
                                             owner = WeakReference<Component> (std::addressof (component))]
        {
            if (owner != nullptr && self->view != nil && self->currentPressId == pressId && ! self->longPressMoved && self->clickedComponent != nullptr)
                self->handleLongPress();
        });

        clickedComponent = component.findComponentAtForMouseEvent (position);

        auto event = makeEvent (position, MouseEvent::leftButton);
        updateComponentUnderTouch (event);

        // Global listeners see the press first: popups close on a tap outside them
        Desktop::getInstance()->handleGlobalMouseDown (MouseEvent (MouseEvent::leftButton, KeyModifiers(), component.localToScreen (position)).withTouchIndex (0));

        if (auto* clicked = clickedComponent.get())
        {
            clicked->internalMouseDown (event.withSourceComponent (clicked).withRelativePositionTo (clicked));
            lastMouseDownPosition = position;
            lastMouseDownTime = Time::getCurrentTime();
        }
    }

    void handleLongPress()
    {
        const auto position = longPressPosition;
        handleMouseUp (position, true);
        ++currentPressId;
        longPressRightClick = true;

        auto* target = component.findComponentAtForMouseEvent (position);

        if (target == nullptr)
            return;

        auto bailOut = Component::BailOutChecker (target);
        auto event = makeEvent (position, MouseEvent::rightButton).withSourceComponent (target);

        Desktop::getInstance()->handleGlobalMouseDown (MouseEvent (MouseEvent::rightButton, KeyModifiers(), component.localToScreen (position)).withTouchIndex (0));
        target->internalMouseDown (event.withRelativePositionTo (target));

        if (! bailOut.shouldBailOut())
            target->internalMouseUp (makeEvent (position, MouseEvent::noButtons).withSourceComponent (target).withRelativePositionTo (target));
    }

    void handleMouseDrag (const Point<float>& position)
    {
        if (position.distanceTo (longPressPosition) > longPressSlop)
            longPressMoved = true;

        auto event = makeEvent (position, MouseEvent::leftButton);

        if (lastMouseDownPosition)
            event = event.withLastMouseDownPosition (*lastMouseDownPosition);

        if (lastMouseDownTime)
            event = event.withLastMouseDownTime (*lastMouseDownTime);

        if (auto* clicked = clickedComponent.get())
            clicked->internalMouseDrag (event.withSourceComponent (clicked).withRelativePositionTo (clicked));

        Desktop::getInstance()->handleGlobalMouseDrag (MouseEvent (MouseEvent::leftButton, KeyModifiers(), component.localToScreen (position)).withTouchIndex (0));
    }

    void handleMouseUp (const Point<float>& position, bool wasCanceled)
    {
        auto event = makeEvent (position, MouseEvent::noButtons);

        if (lastMouseDownPosition)
            event = event.withLastMouseDownPosition (*lastMouseDownPosition);

        if (lastMouseDownTime)
            event = event.withLastMouseDownTime (*lastMouseDownTime);

        auto nativeBailOut = Component::BailOutChecker (&component);

        if (auto* clicked = clickedComponent.get())
        {
            const auto now = Time::getCurrentTime();
            auto clickedBailOut = Component::BailOutChecker (clicked);
            event = event.withSourceComponent (clicked);

            if (! wasCanceled
                && lastMouseUpTime
                && lastClickComponent.get() == clicked
                && lastClickPosition && lastMouseDownPosition && lastClickPosition->distanceTo (*lastMouseDownPosition) < 8.0f
                && now - *lastMouseUpTime < doubleClickTime)
            {
                clicked->internalMouseDoubleClick (event.withRelativePositionTo (clicked));
            }

            if (! clickedBailOut.shouldBailOut())
                clicked->internalMouseUp (event.withRelativePositionTo (clicked));

            if (! wasCanceled)
            {
                lastMouseUpTime = now;
                lastClickPosition = lastMouseDownPosition;
                lastClickComponent = clickedComponent;
            }
        }

        if (nativeBailOut.shouldBailOut())
            return;

        clickedComponent = nullptr;

        // A lifted finger is over nothing
        if (auto* under = componentUnderTouch.get())
            under->internalMouseExit (event.withRelativePositionTo (under));

        componentUnderTouch = nullptr;

        Desktop::getInstance()->handleGlobalMouseUp (MouseEvent (MouseEvent::noButtons, KeyModifiers(), component.localToScreen (position)).withTouchIndex (0));
    }

    //! A finger has no hover: it enters the component under it before pressing it
    void updateComponentUnderTouch (const MouseEvent& event)
    {
        auto* current = component.findComponentAtForMouseEvent (event.getPosition());
        auto* previous = componentUnderTouch.get();

        if (current == previous)
            return;

        if (previous != nullptr)
            previous->internalMouseExit (event.withRelativePositionTo (previous));

        componentUnderTouch = current;

        if (current != nullptr)
            current->internalMouseEnter (event.withRelativePositionTo (current));
    }

    //==============================================================================

    YupUIKitComponentView* view = nil;
    YupUIKitDisplayLinkTarget* displayLinkTarget = nil;
    CADisplayLink* displayLink = nil;

    std::unique_ptr<GraphicsContext> context;
    std::unique_ptr<rive::Renderer> renderer;
    int currentContentWidth = 0;
    int currentContentHeight = 0;

    String title;
    Color clearColor;
    RelativeTime doubleClickTime;
    RepaintMode repaintMode;
    bool shouldRenderContinuous = false;
    bool renderAtomicMode = false;
    bool renderWireframe = false;
    GpuTriangulationThresholds triangulationThresholds;
    std::optional<float> aspectRatio;
    Rectangle<int> screenBounds;
    RectangleList<float> currentRepaintAreas;

    double lastRenderTimeSeconds = 0.0;
    double frameRateStartTimeSeconds = 0.0;
    int frameRateCounter = 0;
    float currentFrameRate = 0.0f;

    WeakReference<Component> focusedComponent;
    WeakReference<Component> currentTextInputComponent;
    WeakReference<Component> clickedComponent;
    WeakReference<Component> componentUnderTouch;
    WeakReference<Component> lastClickComponent;
    Point<float> lastPosition;
    int currentPressId = 0;
    Point<float> longPressPosition;
    bool longPressMoved = false;
    bool longPressRightClick = false;
    std::optional<Point<float>> lastMouseDownPosition;
    std::optional<Time> lastMouseDownTime;
    std::optional<Point<float>> lastClickPosition;
    std::optional<Time> lastMouseUpTime;
};

//==============================================================================

ComponentNative::Ptr createUIKitComponentNative (Component& component, const ComponentNative::Options& options, void* parent)
{
    return ComponentNative::Ptr (ReferenceCountedObjectAdopt, new UIKitComponentNative (component, options, parent));
}

} // namespace yup

//==============================================================================

@implementation YupUIKitComponentView

// The on-screen keyboard (UIKeyInput), while a component takes text

- (BOOL)canBecomeFirstResponder
{
    return self.acceptsText;
}

- (BOOL)hasText
{
    return YES;
}

- (void)insertText:(NSString*)text
{
    if (self.owner == nullptr)
        return;

    if ([text isEqualToString:@"\n"])
        self.owner->handleKey (yup::KeyPress::enterKey);
    else
        self.owner->handleTextInput (yup::String::fromUTF8 ([text UTF8String]));
}

- (void)deleteBackward
{
    if (self.owner != nullptr)
        self.owner->handleKey (yup::KeyPress::backspaceKey);
}

- (UITextAutocorrectionType)autocorrectionType
{
    return UITextAutocorrectionTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType
{
    return UITextAutocapitalizationTypeNone;
}

- (UIReturnKeyType)returnKeyType
{
    return UIReturnKeyDone;
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    if (self.owner != nullptr)
        self.owner->viewDidLayout();
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];

    if (self.owner != nullptr)
        self.owner->viewMovedToWindow();
}

- (void)forwardTouches:(NSSet<UITouch*>*)touches phase:(UITouchPhase)phase
{
    // The first finger is the mouse
    UITouch* touch = [touches anyObject];

    if (touch != nil && self.owner != nullptr)
        self.owner->handleTouch (phase, [touch locationInView:self]);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self forwardTouches:touches phase:UITouchPhaseBegan];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self forwardTouches:touches phase:UITouchPhaseMoved];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self forwardTouches:touches phase:UITouchPhaseEnded];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event
{
    [self forwardTouches:touches phase:UITouchPhaseCancelled];
}

@end

@implementation YupUIKitDisplayLinkTarget

- (void)onDisplayLink:(CADisplayLink*)link
{
    if (self.owner != nullptr)
        self.owner->renderFrame();
}

@end
