% Aidan Hunt
%
% The HoulsbyOpenChannel class implements the open-channel linear momentum
% theory of Houlsby et al. "Application of linear momentum actuator disc
% theory to open channel flow" (2008;
% https://ora.ox.ac.uk/objects/uuid:5576d575-7bac-44b6-ac79-f698edcda40e),
% see also "The Power Available to Tidal Turbines in an Open Channel Flow"
% by Houlsby and Vogel (2017; http://dx.doi.org/10.1680/jener.15.00035).
% Additionally, this code implements the Houlsby et al's linear momentum
% theory as a blockage correction following the implementation of Ross and
% Polagye in "An experimental assessment of analytical blockage
% corrections" (2020; https://doi.org/10.1016/j.renene.2020.01.135).
%
% Open-channel linear momentum on an actuator disk is used to solve for the
% following properties:
%   u1      - Core wake velocity
%   u2      - Bypass velocity
%   ut      - Velocity at the turbine
%   V0Prime - Unconfined freestream velocity
%   Fr      - Depth-based Froude number
%   dhToh   - Free-surface drop across the turbine rotor normalized by
%             upstream depth
% These quantities can then be used for blockage correction or blockage
% forecasting.
%
% To use the HoulsbyOpenChannel class, construct a HoulsbyOpenChannel object
% using the following syntax:
%   hb = HoulsbyOpenChannel()
% and call methods using the dot notation (i.e., hb.solveLMAD(...))
% 
% HoulsbyOpenChannel Methods:
%   solveLMAD         - Solves for flow velocities in the vicinity of the rotor
%                       using open-channel linear momentum on an actuator
%                       disk (LMAD) theory and confined performance data.
%                       No blockage correction is performed.
%   predictUnconfined - Uses open-channel LMAD theory to predict unconfined 
%                       performance from confined performance data.
%                       "Standard" blockage corrections or "bluff body"
%                       blockage corrections may be used.
%   forecastConfined  - Uses open-channel LMAD theory and a bluff body
%                       blockage correction basis to predict performance at
%                       one blockage ratio using data at a different
%                       blockage ratio.
%   linearForecast    - Uses open-channel LMAD theory and an assumption of 
%                       a linear relationship between turbine performance
%                       (i.e., CP, CT) and blockage at constant TSR (e.g.,
%                       as observed by Kinsey and Dumas (2017)) to forecast
%                       performance across blockages.
% 
% The methods above expect that confined performance data is provided as an
% mxn structure array, conf, with the following fields:
%   beta (required)   - blockage ratio
%   V0   (required)   - undisturbed upstream freestream velocity (m/s)
%   d0   (required)   - undisturbed upstream water depth (m)
%   CT   (required)   - thrust coefficient
%   CP   (optional)   - performance coefficient
%   CQ   (optional)   - torque coefficient
%   CL   (optional)   - lateral force coefficient
%   CF   (optional)   - resultant force coefficient
%   TSR  (optional)   - tip-speed ratio
% The fields of conf(i,j) must be vectors that are all the same size. The
% methods above may be used to apply corrections and forecasts to multiple
% datasets at once by specifying each dataset as an element of conf (e.g.,
% conf(i,j)).
%
% These methods utilize helper methods that implement the core equation set
% for the Houlsby-inspired correction as presented in Ross and
% Polagye (2020), which are also available for use. The HoulsbyOpenChannel
% class extends the BCBase and BWClosedChannel classes.
%
% See also: BCBase, BWClosedChannel

classdef HoulsbyOpenChannel < BWClosedChannel

    % The HoulsbyOpenChannel class inherits all properties of the BCBase
    % and BWClosedChannel classes.
    properties (Constant, Access=protected)
        g = 9.81; % Gravitational acceleration
    end

    methods (Access = public)
        %% Main method for solving open-channel linear momentum on an actuator disk
        function [conf] = solveLMAD(hb, conf, uGuess, options)
            % Solves linear momentum on an actuator disk using a
            % open-channel model. Velocities are estimated using
            % Equations 20, 43-45 from Ross and Polagye (2020).
            %
            % Inputs (required)
            %   conf      - A structure of confined performance data with fields
            %               as described in the HoulsbyOpenChannel class documentation.
            % Inputs (optional, positional)
            %   uGuess    - Guess for the value one of the linear momentum
            %               velocities (or ratio between velocities), as a
            %               scalar (default 1.4). See documentation for 
            %               'guessMode' input for valid guess types.
            % Inputs (optional, name-value pairs)
            %   guessMode - The linear momentum velocities (or ratio
            %               between velocities) represented by uGuess:
            %       'u2u1': ratio between u2 and u1 (default)
            %       'u2V0': ratio between u2 and V0
            %       'u2': the bypass velocity
            %   FrZeroLimit - Whether to evaluate linear momentum at the
            %                 closed-channel limit (Fr=0), ignoring the
            %                 provided Froude number. Default: false.
            % Outputs
            %   conf      - The input structure with the following fields
            %               added:
            %               Fr       - Depth-based Froude number (rectangular channel assumed)
            %               dhToh    - Normalized free-surface drop across the rotor
            %               u1       - Wake velocity estimated from closed-channel LMAD
            %               u2       - Bypass velocity estimated from closed-channel LMAD
            %               ut       - Velocity at the turbine estimated from closed-channel LMAD
            %               V0Prime  - Unconfined freestream velocity estimated from closed-channel LMAD
            %               u2u1Iter - Iteration diagnostics for u2/u1
            %               u2Iter   - Iteration diagnostics for u2
            %               isPhys   - Results of physical validity checks on u1, u2, ut
            %
            % See also: HoulsbyOpenChannel, predictUnconfined, forecastConfined, checkPhysicalValidity

            % Define function input arguments, validation, and default
            % values.
            arguments
                hb
                conf
                uGuess (1,1) = [1.04]
                options.guessMode {mustBeText, mustBeMember(options.guessMode, {'u2', 'u2u1', 'u2V0'})} = 'u2u1'
                options.FrZeroLimit (1,1) {mustBeNumericOrLogical} = false;
            end

            % Check input for correct sizing
            conf = hb.checkInputSizes(conf);

            % If considering limiting case of Fr -> 0, set depth to
            % high value.
            if options.FrZeroLimit
                conf = hb.setClosedChannelDepth(conf);
            end

            for i = 1:size(conf, 1) % For each row of the input structure
                for j = 1:size(conf, 2) % For each column of the input structure


                    % Calculate Froude numbers
                    conf(i,j).Fr = hb.calcFroude(conf(i,j).V0, conf(i,j).d0);

                    % If u2 guess is not provided, use closed channel LMAD to generate reasonable u2 guess from a u2u1 guess.
                    switch options.guessMode
                        case 'u2u1'
                            [u2u1, u2u1Err, u2u1ExitFlag] = hb.convergeU2U1(uGuess, conf(i,j));
                            u2Guess = hb.solveU2(u2u1, conf(i,j).CT, conf(i,j).V0);
                        case 'u2V0'
                            u2Guess = uGuess .* conf(i,j).V0;
                        case 'u2'
                            u2Guess = uGuess;
                    end
    
                    % Iterate on Ross and Polagye EQs 43 and 44 to find value of u2 that solves for both.
                    [u2, u2Err, u2ExitFlag] = hb.convergeU2(u2Guess, conf(i,j));
    
                    % Solve for velocities
                    conf(i,j).u1 = hb.solveU1_Thrust(u2, conf(i,j).CT, conf(i,j).V0);
                    conf(i,j).u2 = u2;
                    conf(i,j).ut = hb.solveUt(conf(i,j).u1, conf(i,j).u2, conf(i,j).d0, conf(i,j).V0, conf(i,j).beta);
                    conf(i,j).V0Prime = hb.solveV0Prime(conf(i,j).V0, conf(i,j).CT, conf(i,j).ut);

                    % Solve for depths
                    conf(i,j).hBypass = hb.calcBypassDepth(conf(i,j).d0, conf(i,j).V0, conf(i,j).u2);
                    conf(i,j).hdUp = hb.calcUpstreamDiskDepth(conf(i,j).d0, conf(i,j).V0, conf(i,j).ut);
                    conf(i,j).hdDown = hb.calcDownstreamDiskDepth(conf(i,j).hBypass, conf(i,j).ut, conf(i,j).u1);
                    conf(i,j).dhDisk = hb.calcDiskDrop(conf(i,j).V0, conf(i,j).CT);
                    [conf(i,j).dhToh] = hb.calcTotalSurfaceDeformation(conf(i,j).CT, conf(i,j).beta, conf(i,j).Fr);
                    conf(i,j).hFinal = conf(i,j).d0 .* (1 - conf(i,j).dhToh);

                    % Package diagnostics about u2u1 iteration
                    if strcmp(options.guessMode, 'u2u1')
                        [V0U1_blockage, V0U1_thrust] = hb.solveV0U1_both(u2u1, conf(i,j).beta, conf(i,j).CT);
                        conf(i,j).u2u1Iter = hb.packageDiagnostics(u2u1, [V0U1_blockage, V0U1_thrust], ...
                                                                     u2u1Err, u2u1ExitFlag);
                    end

                    % Package diagnostics about u2 iteration
                    [u1_Fr, u1_Thrust] = hb.solveU1_both(conf(i,j).u2, conf(i,j).beta, conf(i,j).CT, conf(i,j).V0, conf(i,j).Fr);
                    conf(i,j).u2Iter = hb.packageDiagnostics(conf(i,j).u2, [u1_Fr, u1_Thrust], ...
                                                               u2Err, u2ExitFlag);

                    % Check physical validity
                    conf(i,j).isPhys = hb.checkPhysicalValidity(conf(i,j));
                end
            end
        end

        %% Main method for performing blockage correction
        % "predictUnconfined" and "checkScalingVel" are directly inherited
        % from the BWClosedChannel class. predictUnconfined is repeated
        % here to update documenation.

        function [unconf, conf] = predictUnconfined(hb, conf, uGuess, options)
            % Applies open-channel linear momentum on an actuator disk to
            % predict unconfined performance from confined performance
            % data.
            %
            % Inputs (required)
            %   conf      - A structure of confined performance data with fields
            %               as described in the HoulsbyOpenChannel class documentation.
            % Inputs (optional, positional)
            %   uGuess    - Guess for the value one of the linear momentum
            %               velocities (or ratio between velocities), as a
            %               scalar (default 1.4). See documentation for 
            %               'guessMode' input for valid guess types.
            % Inputs (optional, name-value pairs)
            %   guessMode - The linear momentum velocities (or ratio
            %               between velocities) represented by uGuess:
            %       'u2u1': ratio between u2 and u1 (default)
            %       'u2V0': ratio between u2 and V0
            %       'u2': the bypass velocity
            %   FrZeroLimit - Whether to evaluate linear momentum at the
            %                 closed-channel limit (Fr=0), ignoring the
            %                 provided Froude number. Default: false.
            %   correctionType    - Type of blockage correction to apply: 
            %       "standard":     scales the confined data by the unconfined freestream velocity (V0Prime, default)
            %       "bluff body":   scales the confined data by the bypass velocity (u2)
            %   overrideScalingVel - Overrides the scaling velocity used in
            %                        the blockage correction to the one specified. Allowable
            %                        values are 'u1', 'u2', 'ut', or 'V0Prime'
            % Outputs
            %   unconf    - A structure with the same size as the input
            %               conf structure and the following fields (if the
            %               field was not present in conf, it will not be
            %               present in unconf):
            %               V0  - unconfined freestream velocity (equal to specified scaling velocity)
            %               CT  - unconfined thrust coefficient
            %               CP  - unconfined performance coefficient
            %               CQ  - unconfined torque coefficient
            %               CL  - unconfined lateral force coefficient
            %               CF  - unconfined resultant force coefficient
            %               TSR - unconfined tip-speed ratio
            %               velRatio - Ratio between confined freestream
            %                          velocity and unconfined freestream velocity.
            %   conf      - The input structure with the following fields
            %               added:
            %               Fr       - Depth-based Froude number (rectangular channel assumed)
            %               dhToh    - Normalized free-surface drop across the rotor
            %               u1       - Wake velocity estimated from closed-channel LMAD
            %               u2       - Bypass velocity estimated from closed-channel LMAD
            %               ut       - Velocity at the turbine estimated from closed-channel LMAD
            %               V0Prime  - Unconfined freestream velocity estimated from closed-channel LMAD
            %               u2u1Iter - Iteration diagnostics for u2/u1
            %               u2Iter   - Iteration diagnostics for u2
            %               isPhys   - Results of physical validity checks on u1, u2, ut
            %
            % See also: HoulsbyOpenChannel, solveLMAD, forecastConfined, checkPhysicalValidity
    
            % Define function input arguments, validation, and default
            % values.
            arguments
                hb
                conf
                uGuess (1,1) = [1.4]
                options.guessMode {mustBeText, mustBeMember(options.guessMode, {'u2', 'u2u1', 'u2V0'})} = 'u2u1'
                options.FrZeroLimit (1,1) {mustBeNumericOrLogical} = false;
                options.correctionType {mustBeText, ismember(options.correctionType, {'standard', 'bluff body'})} = 'standard'
                options.scalingVelOverride {mustBeText, ismember(options.scalingVelOverride, {'', 'u1', 'u2', 'ut', 'V0Prime'})} = ''
            end

            % If considering the limiting closed-channel case
            if options.FrZeroLimit
                conf = hb.setClosedChannelDepth(conf);
            end

            % Apply closed channel linear momentum model
            conf = hb.solveLMAD(conf, uGuess, guessMode=options.guessMode, FrZeroLimit=options.FrZeroLimit);

            % Convert to unconfined using the appropriate (or requested)
            % scaling velocity
            scalingVelName = hb.checkScalingVel(options.correctionType, options.scalingVelOverride);

            for i = 1:size(conf,1)
                for j = 1:size(conf,2)
                    unconf(i,j) = hb.convertConfToUnconf(conf(i,j), conf(i,j).(scalingVelName));
                end
            end

            % Just call superclass method
            % [unconf, conf] = predictUnconfined@BWClosedChannel(hb, conf, uGuess, guessMode=options.guessMode, correctionType=options.correctionType, scalingVelOverride=options.scalingVelOverride);
        end

        %% Main method for performing bluff-body analytical blockage forecasting
        function [conf_2, conf_1] = forecastConfined(hb, conf_1, beta_2, uGuess, options)
            % Uses an open-channel bluff-body blockage correction to
            % forecast performance at blockage 2 using performance data at
            % blockage 1. The forecast is performed using an analytical
            % relationship that is described in Hunt et al (arxiv link TBD)
            %
            % Inputs (required)
            %   conf_1     - A structure of confined performance data at blockage 1 with fields
            %                as described in the BWClosedChannel class documentation.
            %   beta_2     - The target blockage at which forecasted
            %                performance data is desired, as a fraction.
            % Inputs (optional, positional)
            %   uGuess    - Guess for the value one of the linear momentum
            %               velocities (or ratio between velocities), as a
            %               scalar (default 1.4). See documentation for 
            %               'guessMode' input for valid guess types.
            % Inputs (optional, name-value pairs)
            %   guessMode - The linear momentum velocities (or ratio
            %               between velocities) represented by uGuess:
            %       'u2u1': ratio between u2 and u1 (default)
            %       'u2V0': ratio between u2 and V0
            %       'u2': the bypass velocity
            %   FrZeroLimit - Whether to evaluate linear momentum at the
            %                 closed-channel limit (Fr=0), ignoring the
            %                 provided Froude number. Default: false.
            %   constantFr - Whether to hold the Froude number constant
            %                between beta_1 and beta_2 (true, default) or allow to
            %                vary (false). If constantFr=true, d0 at beta_2
            %                is calculated using Fr at beta_1 and V0 at
            %                beta_2. If constantFr=false, d0 at beta_2 is
            %                calculated using d0 at beta_1 and assuming
            %                constant channel width.
            % Outputs
            %   conf_2     - A structure with the same size and fields as
            %                output conf_1, but with each field corresponding to
            %                the forecasted performance and velocities at beta_2. 
            %   conf_1     - The input structure with the following fields
            %                added:
            %                Fr       - Depth-based Froude number (rectangular channel assumed)
            %                dhToh    - Normalized free-surface drop across the rotor
            %                u1       - Wake velocity estimated from closed-channel LMAD
            %                u2       - Bypass velocity estimated from closed-channel LMAD
            %                ut       - Velocity at the turbine estimated from closed-channel LMAD
            %                V0Prime  - Unconfined freestream velocity estimated from closed-channel LMAD
            %                u2u1Iter - Iteration diagnostics for u2/u1
            %                u2Iter   - Iteration diagnostics for u2
            %                isPhys   - Results of physical validity checks on u1, u2, ut
            %
            % See also: HoulsbyOpenChannel, solveLMAD, predictUnconfined, checkPhysicalValidity

            % Define function input arguments, validation, and default
            % values.
            arguments
                hb
                conf_1
                beta_2 (1,1) {mustBeInRange(beta_2, 0, 1)}
                uGuess (1,1) = [1.4]
                options.guessMode {mustBeText, mustBeMember(options.guessMode, {'u2', 'u2u1', 'u2V0'})} = 'u2u1'
                options.FrZeroLimit (1,1) {mustBeNumericOrLogical} = false;
                options.constantFr (1,1) {mustBeNumericOrLogical} = true;
            end

            if beta_2 == 0 % If 0 blockage requested, just predict unconfined
                [conf_2, conf_1] = hb.predictUnconfined(conf_1, uGuess, guessMode=options.guessMode, ...
                                                        correctionType='bluff body', FrZeroLimit=options.FrZeroLimit);
            else
                % Solve linear actuator disk
                conf_1 = hb.solveLMAD(conf_1, uGuess, guessMode=options.guessMode, FrZeroLimit=options.FrZeroLimit);
    
                % Now, assume that thrust on the rotor is the same at beta_1
                % and beta_2. If thrust is driven by the bypass velocity, then
                % the bypass velocity must be the same between the two cases as
                % well.
    
                for i = 1:size(conf_1, 1)
                    for j = 1:size(conf_1, 2)
    
                        % Generate V0Guess based on beta1 and beta2
                        % V0_2Guess = conf_1(i,j).beta ./ beta_2 .* conf_1(i,j).V0;
                        V0_2Guess = conf_1(i,j).V0; % Try to constrain V0 within reasonable values
    
                        [V0_2, V0_2Err, V0_2ExitFlag] = hb.convergeV02(V0_2Guess, beta_2, conf_1(i,j), options.constantFr);
    
                        % Re-scale data using converged velocity
                        currForecast = hb.convertConfToUnconf(conf_1(i,j), V0_2);
    
                        % Set d0, beta to what was used.
                        if options.constantFr
                            % Calculate d0_2 from Fr_1, V0_2
                            currForecast.d0 = hb.calcDepthFromFroude(currForecast.V0, conf_1(i,j).Fr);
                        else 
                            % Recalculate scaled depth that was used in iteration
                            currForecast.d0 = hb.calcDepthFromBlockage(conf_1(i,j).d0, conf_1(i,j).beta, beta_2);
                        end
                        currForecast.Fr = hb.calcFroude(currForecast.V0, currForecast.d0);
                        currForecast.beta = beta_2;
    
                        % Package diagnostics about V0_2 iteration
                        [u1_Fr, u1_Thrust] = hb.solveU1_both(conf_1(i,j).u2, beta_2, currForecast.CT, currForecast.V0, currForecast.Fr);
                        currForecast.V0_2Iter = hb.packageDiagnostics(currForecast.V0, [u1_Fr, u1_Thrust], ...
                                                                                      V0_2Err, V0_2ExitFlag);
    
                        % Send back through LMAD to get u1, u2
                        % NOTE: This should result in the same u1, u2 as conf_1
                        currForecast = hb.solveLMAD(currForecast, uGuess, guessMode=options.guessMode);
    
                        % Save
                        conf_2(i,j) = currForecast;
                    end
                end
            end
        end

        function [conf_2, conf_1] = linearForecast(hb, conf_1, beta_2, uGuess, options) 
            % Performs a linear prediction of confined performance using
            % the method described by Kinsey and Dumas (2017;
            % 10.1016/j.renene.2016.11.021) and open-channel linear
            % momentum. Performance metrics are assumed to be linear with
            % blockage, such that performance at beta_2 is obtained by
            % linear interpolation/extrapolation between the provided data
            % at beta_1 and the zero-blockage condition obtained using an
            % open-channel blockage correction.
            % Inputs (required)
            %   conf_1     - A structure of confined performance data at blockage 1 with fields
            %                as described in the BWClosedChannel class documentation.
            %   beta_2     - The target blockage at which forecasted
            %                performance data is desired, as a fraction.
            % Inputs (optional, positional)
            %   uGuess    - Guess for the value one of the linear momentum
            %               velocities (or ratio between velocities), as a
            %               scalar (default 1.4). See documentation for 
            %               'guessMode' input for valid guess types.
            % Inputs (optional, name-value pairs)
            %   guessMode - The linear momentum velocities (or ratio
            %               between velocities) represented by uGuess:
            %       'u2u1': ratio between u2 and u1 (default)
            %       'u2V0': ratio between u2 and V0
            %       'u2': the bypass velocity
            %   FrZeroLimit - Whether to evaluate linear momentum at the
            %                 closed-channel limit (Fr=0), ignoring the
            %                 provided Froude number. Default: false.
            %   constantFr - Whether to hold the Froude number constant
            %                between beta_1 and beta_2 (true, default) or allow to
            %                vary (false). If constantFr=true, d0 at beta_2
            %                is calculated using Fr at beta_1 and V0 at
            %                beta_2. If constantFr=false, d0 at beta_2 is
            %                calculated using d0 at beta_1 and assuming
            %                constant channel width.
            %   correctionType    - Type of blockage correction to apply: 
            %       "standard":     scales the confined data by the unconfined freestream velocity (V0Prime, default)
            %       "bluff body":   scales the confined data by the bypass velocity (u2)
            % Outputs
            %   conf_2     - A structure with the same size and fields as
            %                output conf_1, but with each field corresponding to
            %                the forecasted performance at beta_2. 
            %   conf_1     - The input structure with the following fields
            %                added:
            %                Fr       - Depth-based Froude number (rectangular channel assumed)
            %                dhToh    - Normalized free-surface drop across the rotor
            %                u1       - Wake velocity estimated from closed-channel LMAD
            %                u2       - Bypass velocity estimated from closed-channel LMAD
            %                ut       - Velocity at the turbine estimated from closed-channel LMAD
            %                V0Prime  - Unconfined freestream velocity estimated from closed-channel LMAD
            %                u2u1Iter - Iteration diagnostics for u2/u1
            %                u2Iter   - Iteration diagnostics for u2
            %                isPhys   - Results of physical validity checks on u1, u2, ut
            %
            % See also: HoulsbyOpenChannel, solveLMAD, predictUnconfined, checkPhysicalValidity
            arguments
                hb
                conf_1
                beta_2 (1,1) {mustBeInRange(beta_2, 0, 1)}
                uGuess (1,1) = [1.4];
                options.guessMode {mustBeText, mustBeMember(options.guessMode, {'u2', 'u2u1', 'u2V0'})} = 'u2u1'
                options.correctionType {mustBeText, ismember(options.correctionType, {'standard', 'bluff body'})} = 'bluff body'
                options.FrZeroLimit (1,1) {mustBeNumericOrLogical} = false;
            end

            % Perform blockage correction
            unconf = hb.predictUnconfined(conf_1, uGuess, guessMode=options.guessMode, ...
                                                          correctionType=options.correctionType, ...
                                                          FrZeroLimit=options.FrZeroLimit);

            % Perform linear fits at each point
            conf_2 = struct;
            fitFields = {'TSR', 'CP', 'CT', 'CL', 'CQ', 'CF'};
            for i = 1:size(conf_1, 1) % For each row of conf_1
                for j = 1:size(conf_1, 2) % For each column of conf_1
                    % Calculate ratio between beta_2 and beta_1
                    betaRatio = (beta_2 ./ conf_1(i,j).beta);

                    % Set blockage in prediction structure
                    conf_2(i,j).beta = beta_2 .* ones(size(conf_1(i,j).beta));

                    for k = 1:length(fitFields)
                        % Calculate difference in performance between
                        % confined and unconfined performance
                        currData = conf_1(i,j).(fitFields{k});
                        currDataPrime = unconf(i,j).(fitFields{k});

                        % Perform linear interpolation/extrapolation
                        conf_2(i,j).(fitFields{k}) = (currData - currDataPrime) .* betaRatio + currDataPrime;
                    end

                end
            end

        end
    end

    methods (Static, Access = public)

        %% Core Equation set: Ross and Polagye EQs 43-45

        % Ross and Polagye Equation 43
        function [u1, num, den] = solveU1_Froude(u2, beta, CT, V0, Fr)
            % Ross and Polagye Equation 43: solves for u1, the core wake
            % velocity, using a blockage-Froude relationship.
            % Inputs:
            %   u2 - the bypass velocity (m/s)
            %   beta - the channel blockage (decimal)
            %   CT - thrust coefficient at confined condition
            %   V0 - undisturbed freestream velocity at the confined condition (m/s)
            %   Fr - depth-based Froude number at the confined condition
            % Ouputs:
            %   u1 - The core wake velocity (m/s)
            %   num - Numerator of equation 43 (for convergence diagnostics)
            %   den - Denominator of equation 43 (for convergence diagnostics)
            num = (Fr.^2 .* u2.^4) - (4 + 2.*Fr.^2).*(V0.^2 .* u2.^2) + (8.*V0.^3 .* u2) - (4.*V0.^4) + (4.* beta .* CT .* V0.^4) + (Fr.^2 .* V0.^4);
            den = (-4 .* Fr.^2 .* u2.^3) + (4.*Fr.^2 + 8).*(V0.^2 .* u2) - (8.*V0.^3);
            u1 = num ./ den;
        end

        % Ross and Polagye Equation 44:
        function u1 = solveU1_Thrust(u2, CT, V0)
            % Ross and Polagye Equation 44: solves for u1, the core wake
            % velocity, using a thrust relation. Note that this is the same as
            % Ross and Polagye Equation 23, but rearranged.
            % Inputs:
            %   u2 - the bypass velocity (m/s)
            %   CT - thrust coefficient at confined condition
            %   V0 - undisturbed freestream velocity at the confined condition (m/s)
            % Ouputs:
            %   u1 - The core wake velocity (m/s)
            u1 = HoulsbyOpenChannel.solveU1_direct(u2, CT, V0);
        end
        
        % Ross and Polagye Equation 45:
        function ut = solveUt(u1, u2, d0, V0, beta)
            % Ross and Polagye Equation 45: Solves for the velocity at the
            % turbine at the confined condition.
            % Inputs:
            %   u1 - the core wake velocity (m/s)
            %   u2 - the bypass velocity (m/s)
            %   d0 - undisturbed dynamic depth at the confined condition (m)
            %   V0 - undisturbed freestream velocity at the confined condition (m/s)
            %   beta - the channel blockage (decimal)
            % Ouputs:
            %   ut - The velocity at the turbine at the confined condition (m/s)
            num = u1 .* (u2 - V0) .* (2.*HoulsbyOpenChannel.g.*d0 - u2.^2 - u2.*V0);
            den = 2 .* beta .* HoulsbyOpenChannel.g .* d0 .* (u2 - u1);
            ut = num ./ den;
        end

        %% Froude number and dynamic depth calculations

        function Fr = calcFroude(V0, d0)
            % Calculates the depth based Froude number from the input channel
            % depth (d0) and freestream velocity (V0). A rectangular
            % channel is assumed.
            Fr = V0 ./ sqrt(d0 .* HoulsbyOpenChannel.g);
        end
    
        function [d0] = calcDepthFromFroude(V0Target, FrTarget)
            % Given a target Froude number and freestream velocity, calculates
            % the corresponding depth required to meet that condition.
            d0 = V0Target.^2 ./ FrTarget.^2 ./ HoulsbyOpenChannel.g;
        end

        function [d0_2] = calcDepthFromBlockage(d0_1, beta_1, beta_2)
            % Given two blockage states and the depth at one blockage state,
            % computes the depth of the other blockage state assuming constant
            % channel width and turbine area.
            d0_2 = beta_1 ./ beta_2 .* d0_1;
        end

        %% Linear mometum channel depth calculations

        function [dhToh] = calcTotalSurfaceDeformation(CT, beta, Fr)
            % Calculates the normalized free surface drop (dh/h) across
            % turbine rotor using Houlsby et al Equation 4e in Section 9.4,
            % given input CT, beta, and Fr vectors.
            dhToh = zeros(size(CT));
            for i = 1:length(CT)
                dhToh(i) = fzero(@(x) surfaceDefFun(x, CT(i), beta(i), Fr(i)), 0);
            end

            function err = surfaceDefFun(dhToh, CT, beta, Fr)
                % Calculates the normalized free surface drop (dh/h) across
                % turbine rotor using Houlsby et al Equation 4e in Section 9.4,
                % given a known CT, blockage ratio, and Froude number.
                err = 1/2*(dhToh.^3) - 3/2*(dhToh.^2) + (1 - Fr.^2 + (CT.*beta.*Fr.^2)/2)*(dhToh) - (CT .* beta .* Fr.^2)./2;
            end
        end

        function [hdUp] = calcUpstreamDiskDepth(h, V0, ut)
            % Calculates the depth in the core flow just upstream of the
            % actuator disk via Bernoulli, given the upstream undisturbed
            % upstream depth (h), undisturbed inflow velocity (V0), and
            % velocity at the turbine (ut).
            hdUp = h + 1/(2*HoulsbyOpenChannel.g) .* (V0.^2 - ut.^2);
        end

        function [hdDown] = calcDownstreamDiskDepth(h4, ut, u1)
            % Calculates the depth in the core flow just upstream of the
            % actuator disk via Bernoulli, given the depth in the bypass
            % (h4), velocity at the turbine (ut), and velocity in core wake (u1).
            hdDown = h4 + 1/(2*HoulsbyOpenChannel.g) .* (u1.^2 - ut.^2);
        end

        function [dhDisk] = calcDiskDrop(V0, CT)
            % Calculates the free surface drop across the disk given the
            % velcocity and thrust coefficient
            dhDisk = 1/(2*HoulsbyOpenChannel.g) .* CT .* V0.^2;
        end

        function [hBypass] = calcBypassDepth(h, V0, u2)
            % Calculates the depth in the bypass flow/core wake downstream
            % of the actuator disk via Bernoulli, given the undisturbed
            % upstream depth (h), velocity at the turbine (ut), and bypass
            % velocity (u2).
            hBypass = h + 1/(2*HoulsbyOpenChannel.g) .* (V0.^2 - u2.^2);
        end

        % function [conf] = calcLMADDepths(conf)
        %     for i = 1:size(conf,1)
        %         for j = 1:size(conf,2)
        %             % Calculate all depths
        %             conf(i,j).hBypass = calcBypassDepth(conf(i,j).d0, conf(i,j).V0, conf(i,j).u2);
        %             conf(i,j).hdUp = calcUpstreamDiskDepth(conf(i,j).d0, conf(i,j).V0, conf(i,j).ut);
        %             conf(i,j).hdDown = calcUpstreamDiskDepth(conf(i,j).hBypass, conf(i,j).ut, conf(i,j).u1);
        % 
        %             % Calculate drop across the disk predicted by thrust
        %             conf(i,j).dhDisk = calcDiskDrop(conf(i,j).V0, conf(i,j).CT);
        % 
        %             % Calculate total free surface deformation
        %             conf(i,j).dhToh = hb.calcTotalSurfaceDeformation(conf(i,j).CT, conf(i,j).beta, conf(i,j).Fr);
        %         end
        %     end
        % 
        % end

        function conf = setClosedChannelDepth(conf)
            % Overrides the depth in each element of conf to 1e6 to ensure
            % a very low Froude number, such that the limiting case of
            % Fr->0 can be approximated.
            depthVal = 1e6;
            fprintf('Setting depth to %g for open-channel limiting case of Fr -> 0 (closed-channel).\n', depthVal);
            for i = 1:numel(conf)
                conf(i).d0 = depthVal .* ones(size(conf(i).d0));
            end
        end

        %% Iteration scheme for solving for u2 using Ross and Polagye equations 43 and 44
        % CT, V0, Fr are known
        % u2, u1 are unknown

        function [u2, err, exitFlag] = convergeU2(u2Guess, conf)
            % Using Ross and Polagye Equations 43-44, iterates to find u2
            % satisfies both EQ 43 and EQ 44, and returns that u2
            % Inputs:
            %   u2Guess - Initial guess for u2 (as a two element vector for fzero)
            %   conf    - Confined performance data as described in the
            %             HoulsbyOpenChannel class documentation.
            % Outputs:
            %   u2      - Converged values of bypass velocity (m/s)
            %   err     - Error between EQ 43 and EQ 44 at convergence
            %   exitFlag - fzero exit condition

            % Preallocate
            nPoints = length(conf.TSR);
            u2 = zeros(size(conf.TSR));
            err = zeros(size(conf.TSR));
            exitFlag = zeros(size(conf.TSR));

            % Iterate for each point
            for k = 1:nPoints
                % If good point, proceed
                if ~isnan(u2Guess(k)) && (conf.CT(k) >= 0)
                    currFun = @(u2) HoulsbyOpenChannel.u2Compare(u2, conf.beta(k), conf.CT(k), conf.V0(k), conf.Fr(k));

                    % [u2(k), err(k), exitFlag(k)] = fzero(currFun, u2Guess(k,:));
                    [u2(k), err(k), exitFlag(k)] = fminsearch(currFun, u2Guess(k,:));
                else
                    warning('Negative CT value or bad u2Guess: skipping application of LMAD for this point');
                    u2(k) = nan;
                    err(k) = nan;
                    exitFlag(k) = nan;
                end
            end
        end

        function [u1_Fr, u1_Thrust] = solveU1_both(u2, beta, CT, V0, Fr)
            % Calculates u1, the core wake velocity, using Ross and Polagye
            % EQs 43 and 44, and returns the values from each equation
            % Inputs:
            %   u2Guess - Bypass velocity (m/s)
            %   beta - channel blockage ratio
            %   CT - thrust coefficient
            %   V0 - undisturbed freestream velocity (m/s)
            %   Fr - depth-based Froude number
            % Outputs:
            %   u1_Fr - u1 calculated via Ross and Polagye equation 43
            %   u1_Thrust - u1 calculated via Ross and Polagye equation 44
            u1_Fr = HoulsbyOpenChannel.solveU1_Froude(u2, beta, CT, V0, Fr);
            u1_Thrust = HoulsbyOpenChannel.solveU1_Thrust(u2, CT, V0);
        end

        function err = u2Compare(u2Guess, beta, CT, V0, Fr)
            % Calculates u1, the core wake velocity, using Ross and Polagye
            % EQs 43 and 44, and returns the error between the values yielded
            % by each method.
            % Inputs:
            %   u2Guess - Bypass velocity (m/s)
            %   beta - channel blockage ratio
            %   CT - thrust coefficient
            %   V0 - undisturbed freestream velocity (m/s)
            %   Fr - depth-based Froude number
            % Outputs:
            %   err - Error between u1 calculated via Ross and Polagye EQ 43 and
            %         u1 calculated via Ross and Polagye EQ 44
            %
            % ## NOTE: Real part of solution is used to assess convergence
            %          to avoid issues with fminsearch and complex values.

            % Check if physical. If not, make error large
            if u2Guess / V0 <= 1
                err = 1e6;
            else
                % Solve for u1 both ways
                [u1_Fr, u1_Thrust] = HoulsbyOpenChannel.solveU1_both(u2Guess, beta, CT, V0, Fr);
    
                % Error for fzero:
                % err = real(u1_Fr - u1_Thrust); % Take only error of real parts to nudge away from complex solutions
    
                % Error for fminsearch
                err = abs(real(u1_Fr - u1_Thrust));
    
                % Compute error between values
                % err = u1_1 - u1_2; % Compute error between those values
                % err = abs(u1_1) - abs(u1_2); % Take error of magnitudes
            end
        end

        % Visualization
        function [u1Err, ax] = plotU2ConvergenceRegion(u2Test, beta, CT, V0, Fr)
            % Plots the error between the two methods for calculating u1 (used
            % in u2 iteration) for a specific beta, CT, V0, and Fr Useful for
            % visually determining whether a given point can ever converge.

            % Generate test values for u2 and evaluate u1 error for each
            u1Err = HoulsbyOpenChannel.u2Compare(u2Test, beta, CT, V0, Fr);

            % Plot
            [fig] = figure();
            ax = axes(fig);
            grid(ax, 'on'); hold(ax, 'on');
            plot(ax, u2Test, zeros(size(u2Test)), '-k');
            plot(ax, u2Test, u1Err, '-', 'marker', '.');
            xlabel(ax, '$u_2$');
            ylabel(ax, '$u_1$ error');
        end

        %% Iteration scheme for solving for u1 with known u2, unknown V0
        function [V0_2, err, exitFlag] = convergeV02(V0_2Guess, beta_2, conf_1, constantFr)
            % Using Ross and Polagye Equations 43-44 iterates to find V0 
            % that satisfies both EQ 43 and EQ 44, and returns that V0.
            % Used to forecast performance from blockage 1 to blockage 2.
            % Inputs:
            %   V0_2Guess  - A guess for the freestream velocity at beta_2
            %   beta_2     - Target blockage for forecasting (scalar, decimal)
            %   conf_1     - Performance data at starting blockage (beta_1)
            %                formatted as described in HoulsbyOpenChannel
            %                class documentation
            %   constantFr - Whether to hold the Froude number constant
            %                between beta_1 and beta_2 (true) or allow to
            %                vary (false). If constantFr=true, d0 at beta_2
            %                is calculated using Fr at beta_1 and V0 at
            %                beta_2. If constantFr=false, d0 at beta_2 is
            %                calculated using d0 at beta_1 and assuming
            %                constant channel width.
            % Outputs:
            %   V0_2     - Converged value of freestream velocity at beta_2 (m/s)
            %   err      - Error between EQ 43 and EQ 44 at convergence
            %   exitFlag - fzero exit condition

            % Preallocate
            nPoints = length(conf_1.TSR);
            V0_2 = zeros(size(conf_1.TSR));
            err = zeros(size(conf_1.TSR));
            exitFlag = zeros(size(conf_1.TSR));

            % Compute d0_2guess based on Froude number assumption
            if constantFr
                % Let d0_2 vary to hold Fr_1 = Fr_2 as V0_2 varies
                d0_2Guess = NaN .* ones(size(conf_1.d0));
            else 
                % Fix d0_2 based on target blockage, intentionally let Fr vary with V0_2
                d0_2Guess = HoulsbyOpenChannel.calcDepthFromBlockage(conf_1.d0, conf_1.beta, beta_2);
            end

            % Set options
            options = optimset('TolX', 1e-12);

            % Iterate for each point
            for k = 1:nPoints
                currFun = @(V0_2) HoulsbyOpenChannel.V02Compare(V0_2, ...
                                                                d0_2Guess(k), ...
                                                                beta_2, ...
                                                                conf_1.u2(k), ...
                                                                conf_1.CT(k), ...
                                                                conf_1.V0(k), ...
                                                                conf_1.Fr(k));

                % [V0_2(k), err(k), exitFlag] = fzero(currFun, V0_2Guess(k,:), options);
                [V0_2(k), err(k), exitFlag] = fminsearch(currFun, V0_2Guess(k,:), options);
                % [V0_2(k), err(k), exitFlag] = fminbnd(currFun, V0_2Guess(k,:), options);
            end
        end


        function err = V02Compare(V0_2Guess, d0_2Guess, beta_2, u2, CT_1, V0_1, Fr_1)
            % Calculates V0_2, the freestream velocity at blockage 2, using
            % Ross and Polagye EQs 43 and 44, and returns the error between
            % the values yielded by each method.
            % Inputs:
            %   V0_2Guess - Guess for freestream velocity at blockage 2 (m/s)
            %   d0_2Guess - Guess for water depth at blockage 2 (m)
            %   beta_2    - channel blockage ratio at blockage 2
            %   CT_1      - thrust coefficient at blockage 1
            %   V0_1      - undisturbed freestream velocity at blockage 1 (m/s)
            %   Fr_1      - depth-based Froude number at blockage 1
            % Outputs:
            % err - Error between V0_2 calculated via Ross and Polagye EQ 43 and
            %       V0_2 calculated via Ross and Polagye EQ 44
            %
            % ## NOTE: Real part of solution is used to assess convergence
            %          to avoid issues with fminsearch and complex values.
            
            
            % Check that this guess is physical (bypass faster than
            % freestream). If not, give larger error to nudge away from
            % this spot.
            if (u2 / V0_2Guess) <= 1
                err = 1e6; % Give large error to move away from this spot
            else

                % Compute CT
                CT_2 = HoulsbyOpenChannel.scaleForcingMetric(CT_1, V0_1, V0_2Guess);
    
                % Check Fr case
                if ~isnan(d0_2Guess) 
                    % d0_2 is given, then calculate Fr_2 from V0_2 and d0_2
                    Fr_2 = HoulsbyOpenChannel.calcFroude(V0_2Guess, d0_2Guess);
                else 
                    % Otherwise, assume Fr_2 = Fr_1
                    Fr_2 = Fr_1;
                end
                
                % Compute u1 from equation for u1
                [u1_Fr, u1_Thrust] = HoulsbyOpenChannel.solveU1_both(u2, beta_2, CT_2, V0_2Guess, Fr_2);

                % Once again, check if physical (freestream faster than
                % wake). If not, assign large error.
                % if (u1_Fr / V0_2Guess >= 1)
                %     err = 1e6;
                % else
                % Error for fzero
                %err = real(u1_Fr - u1_Thrust); % Error approach for fzero. Take only error of real parts to nudge away from complex solutions
    
                % Error for fminsearch
                err = abs(u1_Fr - u1_Thrust); % Error approach for fminsearch
    
                % Alternative errors
                % err = u1_1 - u1_2; % Compute error between those values
                % err = abs(u1_1) - abs(u1_2); % Take error of magnitudes
                % end
            end
        end


        function [diag] = assessV02ConvergenceRegion(conf, u2V0Test, beta_2)
            % Assesses convergence region for V0_2 in analytical blockage
            % forecasting by decomposing Ross and Polagye Equations 43 and
            % 44. Returns a structure of various intermediate values that
            % arise from the evaluation of these equations, which may be
            % used to assess conditions under which convergence succeeds or
            % fails.
            %
            % Inputs 
            %   conf     - Structure of confined performance data as 
            %              described in the class documentation
            %   u2V0Test - The value of the ratio between u2 and V0 to
            %              evaluate the equations at
            %   beta_2   -
            % Outputs
            %   diag     - A structure of various intermediate values that
            %              arise from the evaluation of Equations 43 and 44,
            %              which may be used to assess conditions under
            %              which convergence succeeds or fails.

            diag = struct;
            for i = 1:size(conf,1)
                for j = 1:size(conf,2)
                    % Compute V0_2 test values from u2V0Test
                    V0_2Test = conf(i,j).u2 ./ u2V0Test;

                    % Determine depth to hold Fr constant in freestream
                    d0_2Test = HoulsbyOpenChannel.calcDepthFromFroude(V0_2Test, conf(i,j).Fr);

                    % Calculate corresponding Froude number in bypass
                    diag(i,j).FrBypass = conf(i,j).u2 ./ sqrt(9.81 * d0_2Test);

                    % Preallocate
                    nPoints = length(conf(i,j).CT);
                    diag(i,j).beta_2 = beta_2;
                    diag(i,j).Fr_2 = conf(i,j).Fr;
                    diag(i,j).V0_2 = V0_2Test;
                    diag(i,j).u1_Fr = zeros(nPoints, length(u2V0Test));
                    diag(i,j).u1_Fr_num = zeros(nPoints, length(u2V0Test));
                    diag(i,j).u1_Fr_den = zeros(nPoints, length(u2V0Test));
                    diag(i,j).u1_Thrust = zeros(nPoints, length(u2V0Test));
                    diag(i,j).CTBetaTerm = zeros(nPoints, length(u2V0Test));
                    diag(i,j).CT = zeros(nPoints, length(u2V0Test));

                    for k = 1:length(conf(i,j).CT) % For each point

                        % Get CT_2
                        CT_2 = HoulsbyOpenChannel.scaleForcingMetric(conf(i,j).CT(k), conf(i,j).V0(k), V0_2Test(k,:));

                        % Solve both equations for wake velocity
                        [u1_Fr, u1_Fr_num, u1_Fr_den] = HoulsbyOpenChannel.solveU1_Froude(conf(i,j).u2(k), beta_2, CT_2, V0_2Test(k,:), conf(i,j).Fr(k));
                        [u1_Thrust] = HoulsbyOpenChannel.solveU1_Thrust(conf(i,j).u2(k), CT_2, V0_2Test(k,:));

                        % Save results
                        diag(i,j).u1_Fr(k,:) = u1_Fr;
                        diag(i,j).u1_Fr_num(k,:) = u1_Fr_num;
                        diag(i,j).u1_Fr_den(k,:) = u1_Fr_den;
                        diag(i,j).u1_Thrust(k,:) = u1_Thrust;

                        % Also compute beta term
                        diag(i,j).CTBetaTerm(k,:) = 4 .* CT_2 .* beta_2 .* V0_2Test(k,:).^4;
                        diag(i,j).CT(k,:) = CT_2;
                    end
                end
            end
        end


        %% Printing stuff out
        function modelName = getModelName()
            % Returns a label-friendly version of the blockage correction
            % model name.
            modelName = 'Houlsby Open-Channel';
        end
    end
end