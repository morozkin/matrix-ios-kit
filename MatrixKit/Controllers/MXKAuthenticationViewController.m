/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAuthenticationViewController.h"

#import "MXKAuthInputsEmailCodeBasedView.h"
#import "MXKAuthInputsPasswordBasedView.h"

#import "MXKAlert.h"

#import "MXKAccountManager.h"

#import "NSBundle+MatrixKit.h"

#import <AFNetworking/AFNetworking.h>

NSString *const MXKAuthErrorDomain = @"MXKAuthErrorDomain";

@interface MXKAuthenticationViewController ()
{
    /**
     The matrix REST client used to make matrix API requests.
     */
    MXRestClient *mxRestClient;
    
    /**
     Current request in progress.
     */
    MXHTTPOperation *mxCurrentOperation;
    
    /**
     The MXKAuthInputsView class or a sub-class used when logging in.
     */
    Class loginAuthInputsViewClass;
    
    /**
     The MXKAuthInputsView class or a sub-class used when registering.
     */
    Class registerAuthInputsViewClass;
    
    /**
     The MXKAuthInputsView class or a sub-class used to handle forgot password case.
     */
    Class forgotPasswordAuthInputsViewClass;
    
    /**
     Customized block used to handle unrecognized certificate (nil by default).
     */
    MXHTTPClientOnUnrecognizedCertificate onUnrecognizedCertificateCustomBlock;
    
    /**
     The current authentication fallback URL (if any).
     */
    NSString *authenticationFallback;
    
    /**
     The cancel button added in navigation bar when fallback page is opened.
     */
    UIBarButtonItem *cancelFallbackBarButton;
    
    /**
     The timer used to postpone the registration when the authentication is pending (for example waiting for email validation)
     */
    NSTimer* registrationTimer;
}

@end

@implementation MXKAuthenticationViewController

#pragma mark - Class methods

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([MXKAuthenticationViewController class])
                          bundle:[NSBundle bundleForClass:[MXKAuthenticationViewController class]]];
}

+ (instancetype)authenticationViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([MXKAuthenticationViewController class])
                                          bundle:[NSBundle bundleForClass:[MXKAuthenticationViewController class]]];
}

#pragma mark -

- (void)finalizeInit
{
    [super finalizeInit];
    
    // Set initial auth type
    _authType = MXKAuthenticationTypeLogin;
    
    // Initialize authInputs view classes
    loginAuthInputsViewClass = MXKAuthInputsPasswordBasedView.class;
    registerAuthInputsViewClass = nil; // No registration flow is supported yet
    forgotPasswordAuthInputsViewClass = nil;
}

#pragma mark -

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    // Check whether the view controller has been pushed via storyboard
    if (!_authenticationScrollView)
    {
        // Instantiate view controller objects
        [[[self class] nib] instantiateWithOwner:self options:nil];
    }
    
    // Load welcome image from MatrixKit asset bundle
    self.welcomeImageView.image = [NSBundle mxk_imageFromMXKAssetsBundleWithName:@"logoHighRes"];
    
    // Adjust bottom constraint of the scroll view in order to take into account potential tabBar
    if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)])
    {
        [NSLayoutConstraint deactivateConstraints:@[_authScrollViewBottomConstraint]];
    }
    else
    {
        [self.view removeConstraint:_authScrollViewBottomConstraint];
    }
    
    _authScrollViewBottomConstraint = [NSLayoutConstraint constraintWithItem:self.bottomLayoutGuide
                                                                   attribute:NSLayoutAttributeTop
                                                                   relatedBy:NSLayoutRelationEqual
                                                                      toItem:self.authenticationScrollView
                                                                   attribute:NSLayoutAttributeBottom
                                                                  multiplier:1.0f
                                                                    constant:0.0f];
    if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)])
    {
        [NSLayoutConstraint activateConstraints:@[_authScrollViewBottomConstraint]];
    }
    else
    {
        [self.view addConstraint:_authScrollViewBottomConstraint];
    }
    
    // Force contentView in full width
    NSLayoutConstraint *leftConstraint = [NSLayoutConstraint constraintWithItem:self.contentView
                                                                      attribute:NSLayoutAttributeLeading
                                                                      relatedBy:0
                                                                         toItem:self.view
                                                                      attribute:NSLayoutAttributeLeading
                                                                     multiplier:1.0
                                                                       constant:0];
    [self.view addConstraint:leftConstraint];
    
    NSLayoutConstraint *rightConstraint = [NSLayoutConstraint constraintWithItem:self.contentView
                                                                       attribute:NSLayoutAttributeTrailing
                                                                       relatedBy:0
                                                                          toItem:self.view
                                                                       attribute:NSLayoutAttributeTrailing
                                                                      multiplier:1.0
                                                                        constant:0];
    [self.view addConstraint:rightConstraint];
    
    [self.view setNeedsUpdateConstraints];
    
    _authenticationScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    _subTitleLabel.numberOfLines = 0;
    
    _submitButton.enabled = NO;
    _authSwitchButton.enabled = YES;
    
    _homeServerTextField.text = _defaultHomeServerUrl;
    _identityServerTextField.text = _defaultIdentityServerUrl;
    
    // Create here REST client (if homeserver is defined)
    [self updateRESTClient];
    
    // Localize labels
    _homeServerLabel.text = [NSBundle mxk_localizedStringForKey:@"login_home_server_title"];
    _homeServerTextField.placeholder = [NSBundle mxk_localizedStringForKey:@"login_server_url_placeholder"];
    _homeServerInfoLabel.text = [NSBundle mxk_localizedStringForKey:@"login_home_server_info"];
    _identityServerLabel.text = [NSBundle mxk_localizedStringForKey:@"login_identity_server_title"];
    _identityServerTextField.placeholder = [NSBundle mxk_localizedStringForKey:@"login_server_url_placeholder"];
    _identityServerInfoLabel.text = [NSBundle mxk_localizedStringForKey:@"login_identity_server_info"];
    [_cancelAuthFallbackButton setTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] forState:UIControlStateNormal];
    [_cancelAuthFallbackButton setTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] forState:UIControlStateHighlighted];
}

- (void)dealloc
{
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    // Force UI update and check the supported authentication flows for the current authentication type.
    self.authType = _authType;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTextFieldChange:) name:UITextFieldTextDidChangeNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self dismissKeyboard];
    
    // close any opened alert
    if (alert)
    {
        [alert dismiss:NO];
        alert = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidChangeNotification object:nil];
}

#pragma mark - Override MXKViewController

- (void)onKeyboardShowAnimationComplete
{
    // Report the keyboard view in order to track keyboard frame changes
    // TODO define inputAccessoryView for each text input
    // and report the inputAccessoryView.superview of the firstResponder in self.keyboardView.
}

- (void)setKeyboardHeight:(CGFloat)keyboardHeight
{
    // Deduce the bottom inset for the scroll view (Don't forget the potential tabBar)
    CGFloat scrollViewInsetBottom = keyboardHeight - self.bottomLayoutGuide.length;
    // Check whether the keyboard is over the tabBar
    if (scrollViewInsetBottom < 0)
    {
        scrollViewInsetBottom = 0;
    }
    
    UIEdgeInsets insets = self.authenticationScrollView.contentInset;
    insets.bottom = scrollViewInsetBottom;
    self.authenticationScrollView.contentInset = insets;
}

- (void)destroy
{
    self.authInputsView = nil;
    
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    if (mxCurrentOperation){
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
    }
    
    [mxRestClient close];
    mxRestClient = nil;

    authenticationFallback = nil;
    cancelFallbackBarButton = nil;
    
    [super destroy];
}

#pragma mark - Class methods

- (void)registerAuthInputsViewClass:(Class)authInputsViewClass forAuthType:(MXKAuthenticationType)authType
{
    // Sanity check: accept only MXKAuthInputsView classes or sub-classes
    NSParameterAssert([authInputsViewClass isSubclassOfClass:MXKAuthInputsView.class]);
    
    if (authType == MXKAuthenticationTypeLogin)
    {
        loginAuthInputsViewClass = authInputsViewClass;
    }
    else if (authType == MXKAuthenticationTypeRegister)
    {
        registerAuthInputsViewClass = authInputsViewClass;
    }
    else if (authType == MXKAuthenticationTypeForgotPassword)
    {
        forgotPasswordAuthInputsViewClass = authInputsViewClass;
    }
}

- (void)setAuthType:(MXKAuthenticationType)authType
{
    if (_authType != authType)
    {
        _authType = authType;
        
        // Cancel external registration parameters if any
        _externalRegistrationParameters = nil;
        
        // Remove the current inputs view
        self.authInputsView = nil;
        
        isPasswordReseted = NO;
        
        [self.authInputsContainerView bringSubviewToFront: _authenticationActivityIndicator];
        [_authenticationActivityIndicator startAnimating];
    }
    
    // Restore user interaction
    self.userInteractionEnabled = YES;
    
    if (authType == MXKAuthenticationTypeLogin)
    {
        _subTitleLabel.hidden = YES;
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"login"] forState:UIControlStateNormal];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"login"] forState:UIControlStateHighlighted];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"create_account"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"create_account"] forState:UIControlStateHighlighted];
        
        // Update supported authentication flow and associated information (defined in authentication session)
        [self refreshAuthenticationSession];
    }
    else if (authType == MXKAuthenticationTypeRegister)
    {
        _subTitleLabel.hidden = NO;
        _subTitleLabel.text = [NSBundle mxk_localizedStringForKey:@"login_create_account"];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"sign_up"] forState:UIControlStateNormal];
        [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"sign_up"] forState:UIControlStateHighlighted];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
        
        // Update supported authentication flow and associated information (defined in authentication session)
        [self refreshAuthenticationSession];
    }
    else if (authType == MXKAuthenticationTypeForgotPassword)
    {
        _subTitleLabel.hidden = YES;
        
        if (isPasswordReseted)
        {
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
        }
        else
        {
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"submit"] forState:UIControlStateNormal];
            [_submitButton setTitle:[NSBundle mxk_localizedStringForKey:@"submit"] forState:UIControlStateHighlighted];
            
            [self refreshForgotPasswordSession];
        }
        
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateNormal];
        [_authSwitchButton setTitle:[NSBundle mxk_localizedStringForKey:@"back"] forState:UIControlStateHighlighted];
    }
}

- (void)setAuthInputsView:(MXKAuthInputsView *)authInputsView
{
    // Here a new view will be loaded, hide first subviews which depend on auth flow
    _submitButton.hidden = YES;
    _noFlowLabel.hidden = YES;
    _retryButton.hidden = YES;
    
    if (_authInputsView)
    {
        [_authInputsView removeObserver:self forKeyPath:@"viewHeightConstraint.constant"];
        
        if ([NSLayoutConstraint respondsToSelector:@selector(deactivateConstraints:)])
        {
            [NSLayoutConstraint deactivateConstraints:_authInputsView.constraints];
        }
        else
        {
            [_authInputsContainerView removeConstraints:_authInputsView.constraints];
        }
        
        [_authInputsView removeFromSuperview];
        _authInputsView.delegate = nil;
        [_authInputsView destroy];
        _authInputsView = nil;
    }
    
    _authInputsView = authInputsView;
    
    CGFloat previousInputsContainerViewHeight = _authInputContainerViewHeightConstraint.constant;
    
    if (_authInputsView)
    {
        _authInputsView.translatesAutoresizingMaskIntoConstraints = NO;
        [_authInputsContainerView addSubview:_authInputsView];
        
        _authInputsView.delegate = self;
        
        _submitButton.hidden = NO;
        _authInputsView.hidden = NO;
        
        _authInputContainerViewHeightConstraint.constant = _authInputsView.viewHeightConstraint.constant;
        
        NSLayoutConstraint* topConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                         attribute:NSLayoutAttributeTop
                                                                         relatedBy:NSLayoutRelationEqual
                                                                            toItem:_authInputsView
                                                                         attribute:NSLayoutAttributeTop
                                                                        multiplier:1.0f
                                                                          constant:0.0f];
        
        
        NSLayoutConstraint* leadingConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                             attribute:NSLayoutAttributeLeading
                                                                             relatedBy:NSLayoutRelationEqual
                                                                                toItem:_authInputsView
                                                                             attribute:NSLayoutAttributeLeading
                                                                            multiplier:1.0f
                                                                              constant:0.0f];
        
        NSLayoutConstraint* trailingConstraint = [NSLayoutConstraint constraintWithItem:_authInputsContainerView
                                                                              attribute:NSLayoutAttributeTrailing
                                                                              relatedBy:NSLayoutRelationEqual
                                                                                 toItem:_authInputsView
                                                                              attribute:NSLayoutAttributeTrailing
                                                                             multiplier:1.0f
                                                                               constant:0.0f];
        
        
        if ([NSLayoutConstraint respondsToSelector:@selector(activateConstraints:)])
        {
            [NSLayoutConstraint activateConstraints:@[topConstraint, leadingConstraint, trailingConstraint]];
        }
        else
        {
            [_authInputsContainerView addConstraint:topConstraint];
            [_authInputsContainerView addConstraint:leadingConstraint];
            [_authInputsContainerView addConstraint:trailingConstraint];
        }
        
        [_authInputsView addObserver:self forKeyPath:@"viewHeightConstraint.constant" options:0 context:nil];
    }
    else
    {
        // No input fields are displayed
        _authInputContainerViewHeightConstraint.constant = _authInputContainerViewMinHeightConstraint.constant;
    }
    
    [self.view layoutIfNeeded];
    
    // Refresh content view height by considering the updated height of inputs container
    _contentViewHeightConstraint.constant += (_authInputContainerViewHeightConstraint.constant - previousInputsContainerViewHeight);
}

- (void)setDefaultHomeServerUrl:(NSString *)defaultHomeServerUrl
{
    _defaultHomeServerUrl = defaultHomeServerUrl;
    
    if (!_homeServerTextField.text.length)
    {
        [self setHomeServerTextFieldText:defaultHomeServerUrl];
    }
}

- (void)setDefaultIdentityServerUrl:(NSString *)defaultIdentityServerUrl
{
    _defaultIdentityServerUrl = defaultIdentityServerUrl;
    
    if (!_identityServerTextField.text.length)
    {
        [self setIdentityServerTextFieldText:defaultIdentityServerUrl];
    }
}

- (void)setHomeServerTextFieldText:(NSString *)homeServerUrl
{
    if (!homeServerUrl.length)
    {
        // Force refresh with default value
        homeServerUrl = _defaultHomeServerUrl;
    }
    
    _homeServerTextField.text = homeServerUrl;
    
    if (!mxRestClient || ![mxRestClient.homeserver isEqualToString:homeServerUrl])
    {
        [self updateRESTClient];
        
        if (_authType == MXKAuthenticationTypeLogin || _authType == MXKAuthenticationTypeRegister)
        {
            // Restore default UI
            self.authType = _authType;
        }
    }
}

- (void)setIdentityServerTextFieldText:(NSString *)identityServerUrl
{
    if (!identityServerUrl.length)
    {
        // Force refresh with default value
        identityServerUrl = _defaultIdentityServerUrl;
    }
    
    _identityServerTextField.text = identityServerUrl;
    
    // Update REST client
    if (![mxRestClient.identityServer isEqualToString:identityServerUrl])
    {
        [mxRestClient setIdentityServer:identityServerUrl];
    }
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled
{
    _submitButton.enabled = (userInteractionEnabled && _authInputsView.areAllRequiredFieldsSet);
    _authSwitchButton.enabled = userInteractionEnabled;
    
    _homeServerTextField.enabled = userInteractionEnabled;
    _identityServerTextField.enabled = userInteractionEnabled;
    
    _userInteractionEnabled = userInteractionEnabled;
}

- (void)refreshAuthenticationSession
{
    // Remove reachability observer
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
    
    // Cancel potential request in progress
    [mxCurrentOperation cancel];
    mxCurrentOperation = nil;
    
    // Reset potential authentication fallback url
    authenticationFallback = nil;
    
    if (mxRestClient)
    {
        if (_authType == MXKAuthenticationTypeLogin)
        {
            mxCurrentOperation = [mxRestClient getLoginSession:^(MXAuthenticationSession* authSession) {
                
                [self handleAuthenticationSession:authSession];
                
            } failure:^(NSError *error) {
                
                [self onFailureDuringMXOperation:error];
                
            }];
        }
        else if (_authType == MXKAuthenticationTypeRegister)
        {
            mxCurrentOperation = [mxRestClient getRegisterSession:^(MXAuthenticationSession* authSession){
                
                [self handleAuthenticationSession:authSession];
                
            } failure:^(NSError *error){
                
                [self onFailureDuringMXOperation:error];
                
            }];
        }
        else
        {
            // Not supported for other types
            NSLog(@"[MXKAuthenticationVC] refreshAuthenticationSession is ignored");
        }
    }
}

- (void)handleAuthenticationSession:(MXAuthenticationSession *)authSession
{
    mxCurrentOperation = nil;
    
    [_authenticationActivityIndicator stopAnimating];
    
    // Check whether fallback is defined, and retrieve the right input view class.
    Class authInputsViewClass;
    if (_authType == MXKAuthenticationTypeLogin)
    {
        authenticationFallback = [mxRestClient loginFallback];
        authInputsViewClass = loginAuthInputsViewClass;
        
    }
    else if (_authType == MXKAuthenticationTypeRegister)
    {
        authenticationFallback = [mxRestClient registerFallback];
        authInputsViewClass = registerAuthInputsViewClass;
    }
    else
    {
        // Not supported for other types
        NSLog(@"[MXKAuthenticationVC] handleAuthenticationSession is ignored");
        return;
    }
    
    MXKAuthInputsView *authInputsView = nil;
    if (authInputsViewClass)
    {
        // Instantiate a new auth inputs view, except if the current one is already an instance of this class.
        if (self.authInputsView && self.authInputsView.class == authInputsViewClass)
        {
            // Use the current view
            authInputsView = self.authInputsView;
        }
        else
        {
            authInputsView = [authInputsViewClass authInputsView];
        }
    }
    
    if (authInputsView)
    {
        // Apply authentication session on inputs view
        if ([authInputsView setAuthSession:authSession withAuthType:_authType] == NO)
        {
            NSLog(@"[MXKAuthenticationVC] Received authentication settings are not supported");
            authInputsView = nil;
        }
        // Check whether all listed flows in this authentication session are supported
        // We suggest using the fallback page (if any), when at least one flow is not supported.
        else if ((authInputsView.authSession.flows.count != authSession.flows.count) && authenticationFallback.length)
        {
            NSLog(@"[MXKAuthenticationVC] Suggest using fallback page");
            authInputsView = nil;
        }
    }
    
    if (authInputsView)
    {
        // Check whether the current view must be replaced
        if (self.authInputsView != authInputsView)
        {
            // Refresh layout
            self.authInputsView = authInputsView;
        }
        
        // Refresh user interaction
        self.userInteractionEnabled = _userInteractionEnabled;
        
        // Check whether an external set of parameters have been defined to pursue a registration
        if (self.externalRegistrationParameters)
        {
            if ([authInputsView setExternalRegistrationParameters:self.externalRegistrationParameters])
            {
                // Launch authentication now
                [self onButtonPressed:_submitButton];
            }
            else
            {
                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                
                _externalRegistrationParameters = nil;
                
                // Restore login screen on failure
                self.authType = MXKAuthenticationTypeLogin;
            }
        }
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
        
        // Cancel external registration parameters if any
        _externalRegistrationParameters = nil;
        
        // Notify user that no flow is supported
        if (_authType == MXKAuthenticationTypeLogin)
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_do_not_support_login_flows"];
        }
        else
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_registration_is_not_supported"];
        }
        NSLog(@"[MXKAuthenticationVC] Warning: %@", _noFlowLabel.text);
        
        if (authenticationFallback.length)
        {
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"login_use_fallback"] forState:UIControlStateNormal];
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"login_use_fallback"] forState:UIControlStateNormal];
        }
        else
        {
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
            [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        }
        
        _noFlowLabel.hidden = NO;
        _retryButton.hidden = NO;
    }
}

- (void)setExternalRegistrationParameters:(NSDictionary*)parameters
{
    if (parameters.count)
    {
        NSLog(@"[MXKAuthenticationVC] setExternalRegistrationParameters");
        
        // Cancel the current operation if any.
        [self cancel];
        
        // Load the view controller’s view if it has not yet been loaded.
        // This is required before updating view's textfields (homeserver url...)
        [self loadViewIfNeeded];
        
        // Force register mode
        self.authType = MXKAuthenticationTypeRegister;
        
        // Apply provided homeserver if any
        id hs_url = parameters[@"hs_url"];
        NSString *homeserverURL = nil;
        if (hs_url && [hs_url isKindOfClass:NSString.class])
        {
            homeserverURL = hs_url;
        }
        [self setHomeServerTextFieldText:homeserverURL];
        
        // Apply provided identity server if any
        id is_url = parameters[@"is_url"];
        NSString *identityURL = nil;
        if (is_url && [is_url isKindOfClass:NSString.class])
        {
            identityURL = is_url;
        }
        [self setIdentityServerTextFieldText:identityURL];
        
        // Disable user interaction
        self.userInteractionEnabled = NO;
        
        // Cancel potential request in progress
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
        
        // Remove the current auth inputs view
        self.authInputsView = nil;
        
        // Set external parameters and trigger a refresh (the parameters will be taken into account during [handleAuthenticationSession:])
        _externalRegistrationParameters = parameters;
        [self refreshAuthenticationSession];
    }
    else
    {
        NSLog(@"[MXKAuthenticationVC] reset externalRegistrationParameters");
        _externalRegistrationParameters = nil;
        
        // Restore default UI
        self.authType = _authType;
    }
}

- (void)setOnUnrecognizedCertificateBlock:(MXHTTPClientOnUnrecognizedCertificate)onUnrecognizedCertificateBlock
{
    onUnrecognizedCertificateCustomBlock = onUnrecognizedCertificateBlock;
}

- (void)isUserNameInUse:(void (^)(BOOL isUserNameInUse))callback
{
    mxCurrentOperation = [mxRestClient isUserNameInUse:self.authInputsView.userId callback:^(BOOL isUserNameInUse) {
        
        mxCurrentOperation = nil;
        
        if (callback)
        {
            callback (isUserNameInUse);
        }
        
    }];
}

- (IBAction)onButtonPressed:(id)sender
{
    [self dismissKeyboard];
    
    if (sender == _submitButton)
    {
        // Disable user interaction to prevent multiple requests
        self.userInteractionEnabled = NO;
        
        // Check parameters validity
        NSString *errorMsg = [self.authInputsView validateParameters];
        if (errorMsg)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:errorMsg}]];
        }
        else
        {
            [self.authInputsContainerView bringSubviewToFront: _authenticationActivityIndicator];
            
            // Launch the authentication according to its type
            if (_authType == MXKAuthenticationTypeLogin)
            {
                // Prepare the parameters dict
                [self.authInputsView prepareParameters:^(NSDictionary *parameters) {
                    
                    if (parameters && mxRestClient)
                    {
                        [_authenticationActivityIndicator startAnimating];
                        [self loginWithParameters:parameters];
                    }
                    else
                    {
                        NSLog(@"[MXKAuthenticationVC] Failed to prepare parameters");
                        [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                    }
                    
                }];
            }
            else if (_authType == MXKAuthenticationTypeRegister)
            {
                // Check here the availability of the userId
                if (self.authInputsView.userId.length)
                {
                    [_authenticationActivityIndicator startAnimating];
                    
                    if (self.authInputsView.password.length)
                    {
                        // Trigger here a register request in order to associate the filled userId and password to the current session id
                        // This will check the availability of the userId at the same time
                        NSDictionary *parameters = @{@"auth": @{},
                                                     @"username": self.authInputsView.userId,
                                                     @"password": self.authInputsView.password,
                                                     @"bind_email": @(NO)};
                        
                        mxCurrentOperation = [mxRestClient registerWithParameters:parameters success:^(NSDictionary *JSONResponse) {
                            
                            // Unexpected case where the registration succeeds without any other stages
                            MXCredentials *credentials = [MXCredentials modelFromJSON:JSONResponse];
                            
                            // Sanity check
                            if (!credentials.userId || !credentials.accessToken)
                            {
                                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                            }
                            else
                            {
                                NSLog(@"[MXKAuthenticationVC] Registration succeeded");
                                // Workaround: HS does not return the right URL. Use the one we used to make the request
                                credentials.homeServer = mxRestClient.homeserver;
                                // Report the certificate trusted by user (if any)
                                credentials.allowedCertificate = mxRestClient.allowedCertificate;
                                
                                [self onSuccessfulLogin:credentials];
                            }
                            
                        } failure:^(NSError *error) {
                            
                            mxCurrentOperation = nil;
                            
                            // An updated authentication session should be available in response data in case of unauthorized request.
                            NSDictionary *JSONResponse = nil;
                            if (error.userInfo[MXHTTPClientErrorResponseDataKey])
                            {
                                JSONResponse = error.userInfo[MXHTTPClientErrorResponseDataKey];
                            }
                            
                            if (JSONResponse)
                            {
                                MXAuthenticationSession *authSession = [MXAuthenticationSession modelFromJSON:JSONResponse];
                                
                                [_authenticationActivityIndicator stopAnimating];
                                
                                // Update session identifier
                                self.authInputsView.authSession.session = authSession.session;
                                
                                // Launch registration by preparing parameters dict
                                [self.authInputsView prepareParameters:^(NSDictionary *parameters) {
                                    
                                    if (parameters && mxRestClient)
                                    {
                                        [_authenticationActivityIndicator startAnimating];
                                        [self registerWithParameters:parameters];
                                    }
                                    else
                                    {
                                        NSLog(@"[MXKAuthenticationVC] Failed to prepare parameters");
                                        [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                                    }
                                    
                                }];
                            }
                            else
                            {
                                [self onFailureDuringAuthRequest:error];
                            }
                        }];
                    }
                    else
                    {
                        [self isUserNameInUse:^(BOOL isUserNameInUse) {
                            
                            if (isUserNameInUse)
                            {
                                NSLog(@"[MXKAuthenticationVC] User name is already use");
                                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"auth_username_in_use"]}]];
                            }
                            else
                            {
                                [_authenticationActivityIndicator stopAnimating];
                               
                                // Launch registration by preparing parameters dict
                                [self.authInputsView prepareParameters:^(NSDictionary *parameters) {
                                    
                                    if (parameters && mxRestClient)
                                    {
                                        [_authenticationActivityIndicator startAnimating];
                                        [self registerWithParameters:parameters];
                                    }
                                    else
                                    {
                                        NSLog(@"[MXKAuthenticationVC] Failed to prepare parameters");
                                        [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                                    }
                                    
                                }];
                            }
                            
                        }];
                    }
                }
                else if (self.externalRegistrationParameters)
                {
                    // Launch registration by preparing parameters dict
                    [self.authInputsView prepareParameters:^(NSDictionary *parameters) {
                        
                        if (parameters && mxRestClient)
                        {
                            [_authenticationActivityIndicator startAnimating];
                            [self registerWithParameters:parameters];
                        }
                        else
                        {
                            NSLog(@"[MXKAuthenticationVC] Failed to prepare parameters");
                            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                        }
                        
                    }];
                }
                else
                {
                    NSLog(@"[MXKAuthenticationVC] User name is missing");
                    [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"auth_invalid_user_name"]}]];
                }
            }
            else if (_authType == MXKAuthenticationTypeForgotPassword)
            {
                // Check whether the password has been reseted
                if (isPasswordReseted)
                {
                    // Return to login screen
                    self.authType = MXKAuthenticationTypeLogin;
                }
                else
                {
                    // Prepare the parameters dict
                    [self.authInputsView prepareParameters:^(NSDictionary *parameters) {
                        
                        if (parameters && mxRestClient)
                        {
                            [_authenticationActivityIndicator startAnimating];
                            [self resetPasswordWithParameters:parameters];
                        }
                        else
                        {
                            NSLog(@"[MXKAuthenticationVC] Failed to prepare parameters");
                            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                        }
                        
                    }];
                }
            }
        }
    }
    else if (sender == _authSwitchButton)
    {
        if (_authType == MXKAuthenticationTypeLogin)
        {
            self.authType = MXKAuthenticationTypeRegister;
        }
        else
        {
            self.authType = MXKAuthenticationTypeLogin;
        }
    }
    else if (sender == _retryButton)
    {
        if (authenticationFallback)
        {
            [self showAuthenticationFallBackView:authenticationFallback];
        }
        else
        {
            [self refreshAuthenticationSession];
        }
    }
    else if (sender == _cancelAuthFallbackButton)
    {
        // Hide fallback webview
        [self hideRegistrationFallbackView];
    }
}

- (void)cancel
{
    NSLog(@"[MXKAuthenticationVC] cancel");
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    // Cancel request in progress
    if (mxCurrentOperation)
    {
        [mxCurrentOperation cancel];
        mxCurrentOperation = nil;
    }
    
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;
    
    // Update authentication inputs view to return in initial step
    [self.authInputsView setAuthSession:self.authInputsView.authSession withAuthType:_authType];
}

- (void)onFailureDuringAuthRequest:(NSError *)error
{
    mxCurrentOperation = nil;
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;
    
    // Ignore connection cancellation error
    if (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled))
    {
        NSLog(@"[MXKAuthenticationVC] Auth request cancelled");
        return;
    }
    
    NSLog(@"[MXKAuthenticationVC] Auth request failed: %@", error);
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    // Translate the error code to a human message
    NSString *title = error.localizedFailureReason;
    if (!title)
    {
        if (self.authType == MXKAuthenticationTypeLogin)
        {
            title = [NSBundle mxk_localizedStringForKey:@"login_error_title"];
        }
        else if (self.authType == MXKAuthenticationTypeRegister)
        {
            title = [NSBundle mxk_localizedStringForKey:@"register_error_title"];
        }
        else
        {
            title = [NSBundle mxk_localizedStringForKey:@"error"];
        }
    }
    NSString* message = error.localizedDescription;
    NSDictionary* dict = error.userInfo;
    
    // detect if it is a Matrix SDK issue
    if (dict)
    {
        NSString* localizedError = [dict valueForKey:@"error"];
        NSString* errCode = [dict valueForKey:@"errcode"];
        
        if (localizedError.length > 0)
        {
            message = localizedError;
        }
        
        if (errCode)
        {
            if ([errCode isEqualToString:kMXErrCodeStringForbidden])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_forbidden"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringUnknownToken])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_unknown_token"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringBadJSON])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_bad_json"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringNotJSON])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_not_json"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringLimitExceeded])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_limit_exceeded"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringUserInUse])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_user_in_use"];
            }
            else if ([errCode isEqualToString:kMXErrCodeStringLoginEmailURLNotYet])
            {
                message = [NSBundle mxk_localizedStringForKey:@"login_error_login_email_not_yet"];
            }
            else if (!message.length)
            {
                message = errCode;
            }
        }
    }
    
    // Alert user
    if (alert)
    {
        [alert dismiss:NO];
    }
    
    alert = [[MXKAlert alloc] initWithTitle:title message:message style:MXKAlertStyleAlert];
    [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"] style:MXKAlertActionStyleCancel handler:^(MXKAlert *alert)
     {}];
    [alert showInViewController:self];
    
    // Update authentication inputs view to return in initial step
    [self.authInputsView setAuthSession:self.authInputsView.authSession withAuthType:_authType];
}

- (void)onSuccessfulLogin:(MXCredentials*)credentials
{
    mxCurrentOperation = nil;
    [_authenticationActivityIndicator stopAnimating];
    self.userInteractionEnabled = YES;
    
    // Sanity check: check whether the user is not already logged in with this id
    if ([[MXKAccountManager sharedManager] accountForUserId:credentials.userId])
    {
        //Alert user
        __weak typeof(self) weakSelf = self;
        alert = [[MXKAlert alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"login_error_already_logged_in"] message:nil style:MXKAlertStyleAlert];
        [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"] style:MXKAlertActionStyleCancel handler:^(MXKAlert *alert) {
            // We remove the authentication view controller.
            [weakSelf withdrawViewControllerAnimated:YES completion:nil];
        }];
        [alert showInViewController:self];
    }
    else
    {
        // Report the new account in account manager
        MXKAccount *account = [[MXKAccount alloc] initWithCredentials:credentials];
        account.identityServerURL = _identityServerTextField.text;
        
        [[MXKAccountManager sharedManager] addAccount:account andOpenSession:YES];
        
        if (_delegate)
        {
            [_delegate authenticationViewController:self didLogWithUserId:credentials.userId];
        }
    }
}

#pragma mark - Privates

- (void)refreshForgotPasswordSession
{
    [_authenticationActivityIndicator stopAnimating];
    
    MXKAuthInputsView *authInputsView = nil;
    if (forgotPasswordAuthInputsViewClass)
    {
        // Instantiate a new auth inputs view, except if the current one is already an instance of this class.
        if (self.authInputsView && self.authInputsView.class == forgotPasswordAuthInputsViewClass)
        {
            // Use the current view
            authInputsView = self.authInputsView;
        }
        else
        {
            authInputsView = [forgotPasswordAuthInputsViewClass authInputsView];
        }
    }
    
    if (authInputsView)
    {
        // Update authentication inputs view to return in initial step
        [authInputsView setAuthSession:nil withAuthType:MXKAuthenticationTypeForgotPassword];
        
        // Check whether the current view must be replaced
        if (self.authInputsView != authInputsView)
        {
            // Refresh layout
            self.authInputsView = authInputsView;
        }
        
        // Refresh user interaction
        self.userInteractionEnabled = _userInteractionEnabled;
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
        
        _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_forgot_password_is_not_supported"];
        
        NSLog(@"[MXKAuthenticationVC] Warning: %@", _noFlowLabel.text);
        
        _noFlowLabel.hidden = NO;
    }
}

- (void)updateRESTClient
{
    NSString *homeserverURL = _homeServerTextField.text;
    
    if (homeserverURL.length)
    {
        // Check change
        if ([homeserverURL isEqualToString:mxRestClient.homeserver] == NO)
        {
            mxRestClient = [[MXRestClient alloc] initWithHomeServer:homeserverURL andOnUnrecognizedCertificateBlock:^BOOL(NSData *certificate) {
                
                // Check first if the app developer provided its own certificate handler.
                if (onUnrecognizedCertificateCustomBlock)
                {
                    return onUnrecognizedCertificateCustomBlock (certificate);
                }
                
                // Else prompt the user by displaying a fingerprint (SHA256) of the certificate.
                __block BOOL isTrusted;
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                
                NSString *title = [NSBundle mxk_localizedStringForKey:@"ssl_could_not_verify"];
                NSString *homeserverURLStr = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"ssl_homeserver_url"], homeserverURL];
                NSString *fingerprint = [NSString stringWithFormat:[NSBundle mxk_localizedStringForKey:@"ssl_fingerprint_hash"], @"SHA256"];
                NSString *certFingerprint = [certificate mx_SHA256AsHexString];
                
                NSString *msg = [NSString stringWithFormat:@"%@\n\n%@\n\n%@\n\n%@\n\n%@\n\n%@", [NSBundle mxk_localizedStringForKey:@"ssl_cert_not_trust"], [NSBundle mxk_localizedStringForKey:@"ssl_cert_new_account_expl"], homeserverURLStr, fingerprint, certFingerprint, [NSBundle mxk_localizedStringForKey:@"ssl_only_accept"]];
                
                alert = [[MXKAlert alloc] initWithTitle:title message:msg style:MXKAlertStyleAlert];
                alert.cancelButtonIndex = [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"cancel"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert){
                    
                    isTrusted = NO;
                    dispatch_semaphore_signal(semaphore);
                    
                }];
                [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"ssl_trust"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert){
                    
                    isTrusted = YES;
                    dispatch_semaphore_signal(semaphore);
                    
                }];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [alert showInViewController:self];
                });
                
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                
                if (!isTrusted)
                {
                    // Cancel request in progress
                    [mxCurrentOperation cancel];
                    mxCurrentOperation = nil;
                    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];

                    [_authenticationActivityIndicator stopAnimating];
                }
                
                return isTrusted;
            }];
            
            if (_identityServerTextField.text.length)
            {
                [mxRestClient setIdentityServer:_identityServerTextField.text];
            }
        }
    }
    else
    {
        [mxRestClient close];
        mxRestClient = nil;
    }
}

- (void)loginWithParameters:(NSDictionary*)parameters
{
    mxCurrentOperation = [mxRestClient login:parameters success:^(NSDictionary *JSONResponse) {
        
        MXCredentials *credentials = [MXCredentials modelFromJSON:JSONResponse];
        
        // Sanity check
        if (!credentials.userId || !credentials.accessToken)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
        }
        else
        {
            NSLog(@"[MXKAuthenticationVC] Login process succeeded");
            
            // Workaround: HS does not return the right URL. Use the one we used to make the request
            credentials.homeServer = mxRestClient.homeserver;
            // Report the certificate trusted by user (if any)
            credentials.allowedCertificate = mxRestClient.allowedCertificate;
            
            [self onSuccessfulLogin:credentials];
        }
        
    } failure:^(NSError *error) {
        
        [self onFailureDuringAuthRequest:error];
        
    }];
}

- (void)registerWithParameters:(NSDictionary*)parameters
{
    if (registrationTimer)
    {
        [registrationTimer invalidate];
        registrationTimer = nil;
    }
    
    mxCurrentOperation = [mxRestClient registerWithParameters:parameters success:^(NSDictionary *JSONResponse) {
        
        MXCredentials *credentials = [MXCredentials modelFromJSON:JSONResponse];
        
        // Sanity check
        if (!credentials.userId || !credentials.accessToken)
        {
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
        }
        else
        {
            NSLog(@"[MXKAuthenticationVC] Registration succeeded");
            // Workaround: HS does not return the right URL. Use the one we used to make the request
            credentials.homeServer = mxRestClient.homeserver;
            // Report the certificate trusted by user (if any)
            credentials.allowedCertificate = mxRestClient.allowedCertificate;
            
            [self onSuccessfulLogin:credentials];
        }
        
    } failure:^(NSError *error) {
        
        mxCurrentOperation = nil;
        
        // Check whether the authentication is pending (for example waiting for email validation)
        MXError *mxError = [[MXError alloc] initWithNSError:error];
        if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringUnauthorized])
        {
            NSLog(@"[MXKAuthenticationVC] Wait for email validation");
            
            // Postpone a new attempt in 10 sec
            registrationTimer = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(registrationTimerFireMethod:) userInfo:parameters repeats:NO];
        }
        else
        {
            // The completed stages should be available in response data in case of unauthorized request.
            NSDictionary *JSONResponse = nil;
            if (error.userInfo[MXHTTPClientErrorResponseDataKey])
            {
                JSONResponse = error.userInfo[MXHTTPClientErrorResponseDataKey];
            }
            
            if (JSONResponse)
            {
                MXAuthenticationSession *authSession = [MXAuthenticationSession modelFromJSON:JSONResponse];
                
                if (authSession.completed)
                {
                    [_authenticationActivityIndicator stopAnimating];
                    
                    // Update session identifier in case of change
                    self.authInputsView.authSession.session = authSession.session;
                    
                    [self.authInputsView updateAuthSessionWithCompletedStages:authSession.completed didUpdateParameters:^(NSDictionary *parameters) {
                        
                        if (parameters)
                        {
                            NSLog(@"[MXKAuthenticationVC] Pursue registration");
                            
                            [_authenticationActivityIndicator startAnimating];
                            [self registerWithParameters:parameters];
                        }
                        else
                        {
                            NSLog(@"[MXKAuthenticationVC] Failed to update parameters");
                            
                            [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
                        }
                        
                    }];
                    
                    return;
                }
                
                [self onFailureDuringAuthRequest:[NSError errorWithDomain:MXKAuthErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey:[NSBundle mxk_localizedStringForKey:@"not_supported_yet"]}]];
            }
            else
            {
                [self onFailureDuringAuthRequest:error];
            }
        }
    }];
}

- (void)registrationTimerFireMethod:(NSTimer *)timer
{
    if (timer == registrationTimer && timer.isValid)
    {
        NSLog(@"[MXKAuthenticationVC] Retry registration");
        [self registerWithParameters:registrationTimer.userInfo];
    }
}

- (void)resetPasswordWithParameters:(NSDictionary*)parameters
{
    mxCurrentOperation = [mxRestClient resetPasswordWithParameters:parameters success:^() {
        
        NSLog(@"[MXKAuthenticationVC] Reset password succeeded");
        
        mxCurrentOperation = nil;
        [_authenticationActivityIndicator stopAnimating];
        
        isPasswordReseted = YES;
        
        // Force UI update to refresh submit button title.
        self.authType = _authType;
        
        // Refresh the authentication inputs view on success.
        [self.authInputsView nextStep];
        
    } failure:^(NSError *error) {
        
        MXError *mxError = [[MXError alloc] initWithNSError:error];
        if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringUnauthorized])
        {
            NSLog(@"[MXKAuthenticationVC] Forgot Password: wait for email validation");
            
            mxCurrentOperation = nil;
            [_authenticationActivityIndicator stopAnimating];
            
            [alert dismiss:NO];
            alert = [[MXKAlert alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"error"] message:[NSBundle mxk_localizedStringForKey:@"auth_reset_password_error_unauthorized"] style:MXKAlertStyleAlert];
            [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"ok"] style:MXKAlertActionStyleCancel handler:^(MXKAlert *alert)
             {}];
            [alert showInViewController:self];
        }
        else if (mxError && [mxError.errcode isEqualToString:kMXErrCodeStringNotFound])
        {
            NSLog(@"[MXKAuthenticationVC] Forgot Password: not found");
            
            NSMutableDictionary *userInfo;
            if (error.userInfo)
            {
                userInfo = [NSMutableDictionary dictionaryWithDictionary:error.userInfo];
            }
            else
            {
                userInfo = [NSMutableDictionary dictionary];
            }
            userInfo[NSLocalizedDescriptionKey] = [NSBundle mxk_localizedStringForKey:@"auth_reset_password_error_not_found"];
            
            [self onFailureDuringAuthRequest:[NSError errorWithDomain:kMXNSErrorDomain code:0 userInfo:userInfo]];
        }
        else
        {
            [self onFailureDuringAuthRequest:error];
        }
        
    }];
}

- (void)onFailureDuringMXOperation:(NSError*)error
{
    mxCurrentOperation = nil;
    
    [_authenticationActivityIndicator stopAnimating];
    
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
    {
        // Ignore this error
        NSLog(@"[MXKAuthenticationVC] flows request cancelled");
        return;
    }
    
    NSLog(@"[MXKAuthenticationVC] Failed to get %@ flows: %@", (_authType == MXKAuthenticationTypeLogin ? @"Login" : @"Register"), error);
    
    // Cancel external registration parameters if any
    _externalRegistrationParameters = nil;
    
    // Alert user
    NSString *title = [error.userInfo valueForKey:NSLocalizedFailureReasonErrorKey];
    if (!title)
    {
        title = [NSBundle mxk_localizedStringForKey:@"error"];
    }
    NSString *msg = [error.userInfo valueForKey:NSLocalizedDescriptionKey];
    
    alert = [[MXKAlert alloc] initWithTitle:title message:msg style:MXKAlertStyleAlert];
    alert.cancelButtonIndex = [alert addActionWithTitle:[NSBundle mxk_localizedStringForKey:@"dismiss"] style:MXKAlertActionStyleDefault handler:^(MXKAlert *alert) {}];
    [alert showInViewController:self];
    
    // Handle specific error code here
    if ([error.domain isEqualToString:NSURLErrorDomain])
    {
        // Check network reachability
        if (error.code == NSURLErrorNotConnectedToInternet)
        {
            // Add reachability observer in order to launch a new request when network will be available
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onReachabilityStatusChange:) name:AFNetworkingReachabilityDidChangeNotification object:nil];
        }
        else if (error.code == kCFURLErrorTimedOut)
        {
            // Send a new request in 2 sec
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self refreshAuthenticationSession];
            });
        }
        else
        {
            // Remove the potential auth inputs view
            self.authInputsView = nil;
        }
    }
    else
    {
        // Remove the potential auth inputs view
        self.authInputsView = nil;
    }
    
    if (!_authInputsView)
    {
        // Display failure reason
        _noFlowLabel.hidden = NO;
        _noFlowLabel.text = [error.userInfo valueForKey:NSLocalizedDescriptionKey];
        if (!_noFlowLabel.text.length)
        {
            _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"login_error_no_login_flow"];
        }
        [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        [_retryButton setTitle:[NSBundle mxk_localizedStringForKey:@"retry"] forState:UIControlStateNormal];
        _retryButton.hidden = NO;
    }
}

- (void)onReachabilityStatusChange:(NSNotification *)notif
{
    AFNetworkReachabilityManager *reachabilityManager = [AFNetworkReachabilityManager sharedManager];
    AFNetworkReachabilityStatus status = reachabilityManager.networkReachabilityStatus;
    
    if (status == AFNetworkReachabilityStatusReachableViaWiFi || status == AFNetworkReachabilityStatusReachableViaWWAN)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAuthenticationSession];
        });
    }
    else if (status == AFNetworkReachabilityStatusNotReachable)
    {
        _noFlowLabel.text = [NSBundle mxk_localizedStringForKey:@"network_error_not_reachable"];
    }
}

#pragma mark - Keyboard handling

- (void)dismissKeyboard
{
    // Hide the keyboard
    [_authInputsView dismissKeyboard];
    [_homeServerTextField resignFirstResponder];
    [_identityServerTextField resignFirstResponder];
}

#pragma mark - UITextField delegate

- (void)onTextFieldChange:(NSNotification *)notif
{
    _submitButton.enabled = _authInputsView.areAllRequiredFieldsSet;
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField
{
    if (textField == _homeServerTextField)
    {
        // Cancel supported AuthFlow refresh if a request is in progress
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNetworkingReachabilityDidChangeNotification object:nil];
        
        if (mxCurrentOperation)
        {
            // Cancel potential request in progress
            [mxCurrentOperation cancel];
            mxCurrentOperation = nil;
        }
    }

    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (textField == _homeServerTextField)
    {
        [self setHomeServerTextFieldText:textField.text];
    }
    else if (textField == _identityServerTextField)
    {
        [self setIdentityServerTextFieldText:textField.text];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
    if (textField.returnKeyType == UIReturnKeyDone)
    {
        // "Done" key has been pressed
        [textField resignFirstResponder];
    }
    return YES;
}

#pragma mark - AuthInputsViewDelegate delegate

- (void)authInputsView:(MXKAuthInputsView*)authInputsView presentMXKAlert:(MXKAlert*)inputsAlert
{
    [self dismissKeyboard];
    [inputsAlert showInViewController:self];
}

- (void)authInputsViewDidPressDoneKey:(MXKAuthInputsView *)authInputsView
{
    if (_submitButton.isEnabled)
    {
        // Launch authentication now
        [self onButtonPressed:_submitButton];
    }
}

- (MXRestClient *)authInputsViewThirdPartyIdValidationRestClient:(MXKAuthInputsView *)authInputsView
{
    return mxRestClient;
}

#pragma mark - Authentication Fallback

- (void)showAuthenticationFallBackView:(NSString*)fallbackPage
{
    _authenticationScrollView.hidden = YES;
    _authFallbackContentView.hidden = NO;
    
    // Add a cancel button in case of navigation controller use.
    if (self.navigationController)
    {
        if (!cancelFallbackBarButton)
        {
            cancelFallbackBarButton = [[UIBarButtonItem alloc] initWithTitle:[NSBundle mxk_localizedStringForKey:@"login_leave_fallback"] style:UIBarButtonItemStylePlain target:self action:@selector(hideRegistrationFallbackView)];
        }
        
        // Add cancel button in right bar items
        NSArray *rightBarButtonItems = self.navigationItem.rightBarButtonItems;
        self.navigationItem.rightBarButtonItems = rightBarButtonItems ? [rightBarButtonItems arrayByAddingObject:cancelFallbackBarButton] : @[cancelFallbackBarButton];
    }
    
    [_authFallbackWebView openFallbackPage:fallbackPage success:^(MXCredentials *credentials) {
        
        // Workaround: HS does not return the right URL. Use the one we used to make the request
        credentials.homeServer = mxRestClient.homeserver;
        
        // TODO handle unrecognized certificate (if any) during registration through fallback webview.
        
        [self onSuccessfulLogin:credentials];
    }];
}

- (void)hideRegistrationFallbackView
{
    if (cancelFallbackBarButton)
    {
        NSMutableArray *rightBarButtonItems = [NSMutableArray arrayWithArray: self.navigationItem.rightBarButtonItems];
        [rightBarButtonItems removeObject:cancelFallbackBarButton];
        self.navigationItem.rightBarButtonItems = rightBarButtonItems;
    }
    
    [_authFallbackWebView stopLoading];
    _authenticationScrollView.hidden = NO;
    _authFallbackContentView.hidden = YES;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([@"viewHeightConstraint.constant" isEqualToString:keyPath])
    {
        // Refresh the height of the auth inputs view container.
        CGFloat previousInputsContainerViewHeight = _authInputContainerViewHeightConstraint.constant;
        _authInputContainerViewHeightConstraint.constant = _authInputsView.viewHeightConstraint.constant;
        
        // Force to render the view
        [self.view layoutIfNeeded];
        
        // Refresh content view height by considering the updated height of inputs container
        _contentViewHeightConstraint.constant += (_authInputContainerViewHeightConstraint.constant - previousInputsContainerViewHeight);
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

@end
