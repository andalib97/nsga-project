%% HRES_Run_Optimization.m
% NSGA-II driver using NGPM for the HRES retrofit problem.

clear; clc;

% --- 0) Ensure demand/resource data are present (from Script 1) ---
% If you haven't run the setup in this session, uncomment:
% HRES_Data_and_Model_Setup_Script;

% --- 1) NGPM options ---
rng(129);                                % reproducibility

opt              = nsgaopt();            % NGPM options structure (v1.4)
opt.numObj       = 2;                    % [AnnualizedCost, DieselFraction]
opt.numVar       = 7;                    % [PV,Wind,VRFB_E,VRFB_P,AACAES_E,AACAES_P,Diesel]
opt.numCons      = 0;                    % we penalize reliability in objfun
opt.popsize      = 10;                   % tune up for real runs
opt.maxGen       = 20;                   % tune up for convergence
opt.pcross       = 0.9;
opt.pmut         = 0.1;
opt.vartype      = ones(1,opt.numVar);   % all real-coded
opt.objfun       = @HRES_objFun_2;       % your Script (2) objective

% Optional: names for axes in plotnsga(result)
opt.nameObj      = {'Annualized Cost [$]','Diesel Energy Fraction [-]'};

% --- 2) Variable bounds (kW/kWh; widen as needed for your case) ---
LB = [   0,    0,      0,     0,       0,      0,   2000];  % keep a small diesel floor if desired
UB = [40000, 40000, 400000, 20000, 1000000, 30000, 30000];

opt.lb = LB;
opt.ub = UB;

% --- 3) Run NSGA-II (NGPM v1.4) ---
fprintf('Running NSGA-II... Pop=%d, Gen=%d\n', opt.popsize, opt.maxGen);
result = nsga2(opt);                     % returns structure w/ pops, states, etc. (v1.4)

% --- 4) Extract last generation population (vars & objs) ---
lastPop  = result.pops(end, :);          % final generation, array of individuals
F        = cat(1, lastPop.obj);          % [N x 2] objectives: [cost, diesel_frac]
V        = cat(1, lastPop.var);          % [N x 7] decision variables

% --- 5) Get Pareto front (first non-dominated front) ---
% Try the local ndsort signature(s) if present; else use a safe fallback.
if exist('ndsort','file') == 2
    try
        % Most compact signature: ndsort(F) -> FrontNo (some NGPM drops use this)
        FrontNo = ndsort(F);
    catch
        try
            % PlatEMO-style signature: ndsort(F, s) -> [FrontNo, MaxFNo]
            [FrontNo, ~] = ndsort(F, size(F,1));
        catch
            % Final attempt: ndsort(F, [], 'min') if user’s variant supports it
            try
                [FrontNo, ~] = ndsort(F, [], 'min');
            catch
                % Fallback if none of the above work
                FrontNo = localFirstFront(F);
            end
        end
    end
elseif exist('NDSort','file') == 2
    % PlatEMO-style function name
    [FrontNo, ~] = NDSort(F, size(F,1));
else
    % Safe O(N^2) fallback (first front only)
    FrontNo = localFirstFront(F);
end

paretoIdx = find(FrontNo == 1);
paretoF   = F(paretoIdx, :);      % objectives on PF
paretoV   = V(paretoIdx, :);      % decision vars on PF

% ---- helper (place at end of file or as a local function) ----
function FrontNo = localFirstFront(F)
n = size(F,1);
isND = true(n,1);
for i = 1:n
    for j = 1:n
        if j ~= i && all(F(j,:) <= F(i,:)) && any(F(j,:) < F(i,:))
            isND(i) = false; break;
        end
    end
end
FrontNo         = inf(n,1);
FrontNo(isND)   = 1;
end

% --- 6) Save outputs (use datetime instead of datestr) ---
ts     = char(datetime('now','Format','yyyyMMdd_HHmmss'));
outdir = fullfile(pwd, ['HRES_NSGA_' ts]);
if ~exist(outdir,'dir'); mkdir(outdir); end

save(fullfile(outdir,'nsga_result.mat'), 'result','opt','LB','UB');
save(fullfile(outdir,'final_generation.mat'), 'F','V','FrontNo');
save(fullfile(outdir,'pareto_front.mat'),      'paretoF','paretoV','paretoIdx');

% --- 7) Console summary ---
fprintf('Pareto points: %d | Cost [$]: [%.2fM .. %.2fM] | Diesel frac: [%.3f .. %.3f]\n', ...
    numel(paretoIdx), min(paretoF(:,1))/1e6, max(paretoF(:,1))/1e6, ...
    min(paretoF(:,2)), max(paretoF(:,2)));

% Optional quick plot (comment out for headless runs)
figure('Color','w'); scatter(F(:,1)/1e6, F(:,2), 24, [0.6 0.6 0.6], 'filled'); hold on;
scatter(paretoF(:,1)/1e6, paretoF(:,2), 36, 'r', 'filled');
grid on; xlabel('Annualized Cost [Million $]'); ylabel('Diesel Energy Fraction [-]');
title('Final Generation & Pareto Front (highlighted)');
legend('Final gen','Pareto front','Location','best');
