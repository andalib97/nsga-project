%% TP_run_nsga.m  (rev D)
% Driver for HRES sizing with NGPM/NSGA-II:
% - runs optimizer
% - plots Pareto front
% - OPTIONAL: filters by budget / reliability / diesel share
% - selects a knee design from the filtered set
% - plots year-by-year energy mix for that knee

clear; clc;

%% ------------------ Ensure NGPM is on the MATLAB path ------------------
% addpath(genpath('path/to/NGPM'));   % must contain nsgaopt.m, nsga2.m, etc.
if ~exist('nsgaopt','file') || ~exist('nsga2','file')
    error(['NGPM not found on path. Add the folder containing nsgaopt.m/nsga2.m ', ...
           'to your MATLAB path and try again.']);
end

%% ------------------------- Prepare shared data -------------------------
if ~exist('HRES_DATA.mat','file'), run('HRES_setup.m'); end
load HRES_DATA.mat
global HRES_DATA

% Build scenarios if missing or empty
if ~isfield(HRES_DATA,'scenarios') || ~isfield(HRES_DATA.scenarios,'GHI') ...
   || isempty(HRES_DATA.scenarios.GHI)
    run('HRES_make_scenarios.m'); load HRES_DATA.mat
end

params = HRES_DATA.params;
bounds = HRES_DATA.bounds;

fprintf('--- HRES Ready ---\n');
fprintf(' Δt = %.2f h, steps/year = %d, years = %d, reliability mode = %s\n', ...
    params.dt_hours, params.hours_year, params.n_years, string(params.reliability_mode));
fprintf(' Decision vars: %s\n', strjoin(bounds.names, ', '));

%% --------------------- Sanity check the objective ----------------------
x0 = (bounds.lb + bounds.ub) / 2;
[f0, ~] = HRES_objfun(x0);
fprintf(' Sanity-check at mid-bounds: CC = %.2f, LPSP_m = %.3f\n', f0(1), f0(2));

%% ----------------------- Configure NGPM options ------------------------
options = nsgaopt();
options.numObj  = 2;                      % [CC, LPSP_m]
options.numVar  = numel(bounds.lb);
options.popsize = 20;
options.maxGen  = 20;
options.lb      = bounds.lb(:)';          % row vectors
options.ub      = bounds.ub(:)';
options.objfun  = @HRES_objfun;

% Eliminate vartype warning & enforce integer scheme (if provided)
if isfield(bounds,'vartype'), options.vartype = bounds.vartype(:)'; end
if isfield(bounds,'nameVar'), options.nameVar = bounds.nameVar; end

% Optional: parallel (if you have Parallel Toolbox)
% options.useParallel = 'yes'; options.poolsize = 4;
% rng(1234);  % reproducibility

%% --------------------------- Run NSGA-II -------------------------------
if ~exist('result','var') || isempty(result)
    tic; result = nsga2(options); t_elapsed = toc;
    fprintf('NSGA-II complete in %.1f s\n', t_elapsed);
    fname = sprintf('NSGA_result_%s.mat', datestr(now,'yyyymmdd_HHMMSS'));
    save(fname, 'result'); fprintf('Saved result to %s\n', fname);
else
    fprintf('Reusing existing ''result'' (skipping NSGA run)\n');
end

%% --------------------------- Plot Pareto -------------------------------
try
    hFig = figure; plotnsga(result); title('Pareto Front: [Capital Cost, LPSP_m]');
catch
    [Xtmp,Ftmp] = local_get_XF(result);
    hFig = figure; scatter(Ftmp(:,1), Ftmp(:,2), 16, 'filled');
    grid on; xlabel('Capital Cost (CC)'); ylabel('LPSP_m');
    title('Pareto Front (fallback scatter)');
end

%% --------------------- Extract Pareto arrays ---------------------------
[X,F] = local_get_XF(result);
if isempty(X) || isempty(F)
    fn = fieldnames(result);
    error('Could not extract decision/objective arrays from result. Fields: %s', strjoin(fn,', '));
end

% Keep non-dominated only (no-op if already Pareto)
[idx_nd, ~] = local_nondominated(F);
Xnd = X(idx_nd, :);  Fnd = F(idx_nd, :);

% Guard against empty fronts (bad objective values / failed run)
if isempty(Xnd) || isempty(Fnd)
    error('Non-dominated set is empty. Check NGPM result content or objective values.');
end

%% --------------------- OPTIONAL FILTERS (set here) ---------------------
filters.enable            = true;   % turn all filtering on/off
filters.budget_cap        = NaN;    % e.g., 5e7 (NaN disables)
filters.LPSP_m_cap        = 0.10;   % ≤10% failed years
filters.diesel_share_cap  = 0.30;   % ≤30% diesel share
filters.use_pctl          = [];     % e.g., 90 to use P90; [] => mean

Xsel = Xnd; Fsel = Fnd;
mask  = true(size(Fnd,1),1);

if filters.enable
    if ~isnan(filters.budget_cap), mask = mask & (Fnd(:,1) <= filters.budget_cap); end
    if ~isnan(filters.LPSP_m_cap), mask = mask & (Fnd(:,2) <= filters.LPSP_m_cap); end

    if ~isnan(filters.diesel_share_cap)
        fprintf(' Evaluating diesel share for %d Pareto points ...\n', size(Xnd,1));
        [ds_mean, ds_pctl] = local_diesel_share_for_set(Xnd, params, HRES_DATA);
        if isempty(filters.use_pctl)
            mask = mask & (ds_mean <= filters.diesel_share_cap);
            fprintf('  • Applied diesel-share cap on MEAN ≤ %.2f\n', filters.diesel_share_cap);
        else
            mask = mask & (ds_pctl <= filters.diesel_share_cap);
            fprintf('  • Applied diesel-share cap on P%02d ≤ %.2f\n', filters.use_pctl, filters.diesel_share_cap);
        end
        try
            figure(hFig); hold on;
            scatter(Fnd(mask,1), Fnd(mask,2), 26, '^', 'filled', 'DisplayName','Filtered set');
            legend('show');
        catch, end
    end

    if any(mask)
        Xsel = Xnd(mask,:); Fsel = Fnd(mask,:);
        fprintf(' Filter kept %d / %d Pareto points.\n', size(Xsel,1), size(Xnd,1));
    else
        fprintf(' Filter removed all points — reverting to full Pareto set.\n');
        Xsel = Xnd; Fsel = Fnd;
    end
end

%% --------------------- Pick knee from the (filtered) set ---------------
[knee_idx, knee_score] = local_pick_knee(Fsel);
x_knee  = Xsel(knee_idx,:);   f_knee = Fsel(knee_idx,:);

fprintf('\n--- Knee selection (after filters) ---\n');
fprintf(' Knee index = %d (score %.3f)\n', knee_idx, knee_score);
fprintf(' Knee design:  CC = %.2f,  LPSP_m = %.4f\n', f_knee(1), f_knee(2));

% Highlight knee
try
    figure(hFig); hold on;
    plot(f_knee(1), f_knee(2), 'kp', 'MarkerSize', 12, 'MarkerFaceColor', 'y', 'DisplayName','Knee');
    legend('show');
catch, end

%% ------------------- Build design & save a snapshot --------------------
design = local_build_design(x_knee);
save(sprintf('NSGA_result_w_knee_%s.mat', datestr(now,'yyyymmdd_HHMMSS')), 'result', 'design', 'f_knee', 'x_knee');

%% ---------- Post-process: energy mix across years for the knee ----------
if exist('HRES_energy_mix_years.m','file')
    HRES_energy_mix_years(design, true);   % true = save PNG+CSV
else
    warning('HRES_energy_mix_years.m not found; skipping energy-mix plot.');
end

disp('x_knee ='); disp(x_knee);
[ff,~] = HRES_objfun(x_knee); disp('HRES_objfun(x_knee) ='); disp(ff);

fprintf('\nDone. Artifacts generated:\n');
fprintf('  • Pareto front figure\n');
fprintf('  • Knee design saved to MAT file\n');
fprintf('  • Energy-mix plot (PNG) and CSV across years for the knee design\n');

%% ========================== Local helpers ==============================
function [X,F] = local_get_XF(result, whichGen)
X = []; F = [];
if nargin < 2, whichGen = []; end
if isstruct(result)
    if isfield(result,'pops') && ~isempty(result.pops)
        nGen = size(result.pops,1);
        if isempty(whichGen) || whichGen > nGen, whichGen = nGen; end
        pop = result.pops(whichGen,:);        % row of structs
        if isstruct(pop) && isfield(pop,'var') && isfield(pop,'obj')
            X = vertcat(pop.var);
            F = vertcat(pop.obj);
            return;
        end
    end
    if isfield(result,'pareto_v') && isfield(result,'pareto_f')
        try,  X = vertcat(result.pareto_v{:}); F = vertcat(result.pareto_f{:}); return; catch, end
    end
    if isfield(result,'var') && isfield(result,'fun')
        X = result.var; F = result.fun; return;
    end
end
end

function [idx_nd, is_dom] = local_nondominated(F)
n = size(F,1); is_dom = false(n,1);
for i = 1:n
    if is_dom(i), continue; end
    for j = 1:n
        if i==j, continue; end
        if all(F(j,:) <= F(i,:)) && any(F(j,:) < F(i,:))
            is_dom(i) = true; break;
        end
    end
end
idx_nd = find(~is_dom);
end

function [knee_idx, score] = local_pick_knee(F)
Fmin = min(F,[],1);
Fmax = max(F,[],1);
range = max(Fmax - Fmin, eps);
F2 = (F - Fmin)./range;
[~, i1] = min(F2(:,1)); [~, i2] = min(F2(:,2));
p1 = F2(i1,:); p2 = F2(i2,:);
v  = p2 - p1;  nv = norm(v);
if nv < 1e-9, [~, knee_idx] = min(sum(F2,2)); score = NaN; return; end
num = abs((F2 - p1) * [v(2); -v(1)]);
d   = num / nv;
[dmax, knee_idx] = max(d);
score = dmax;
end

function d = local_build_design(x)
d = struct('PV_kW',x(1),'WT_kW',x(2), ...
           'AA_E',x(3),'AA_P',x(4), ...
           'VR_E',x(5),'VR_P',x(6), ...
           'DG_P',x(7),'scheme',max(1,min(3,round(x(8)))));
end

function [ds_mean, ds_pctl] = local_diesel_share_for_set(Xset, params, HRES_DATA)
n = size(Xset,1);
ds_mean = nan(n,1);
ds_pctl = nan(n,1);
tech      = HRES_DATA.tech;
diesel    = HRES_DATA.diesel;
scenarios = HRES_DATA.scenarios;
for i = 1:n
    x = Xset(i,:);
    d = struct('PV_kW',x(1),'WT_kW',x(2), ...
               'AA_E',x(3),'AA_P',x(4), ...
               'VR_E',x(5),'VR_P',x(6), ...
               'DG_P',x(7),'scheme',max(1,min(3,round(x(8)))));
    try
        [~, info] = reliability_metrics(d, params, tech, diesel, scenarios);
        if isfield(info,'diesel_share_years') && ~isempty(info.diesel_share_years)
            ds = info.diesel_share_years(:);
            ds_mean(i) = mean(ds,'omitnan');
            ds_pctl(i) = pctile_fallback(ds, 90);   % no Stats Toolbox needed
        else
            ds_mean(i) = NaN; ds_pctl(i) = NaN;
        end
    catch
        ds_mean(i) = NaN; ds_pctl(i) = NaN;
    end
end
end

function p = pctile_fallback(v, q)
v = v(:); v = v(isfinite(v));
if isempty(v), p = NaN; return; end
if exist('prctile','file') ~= 0
    p = prctile(v, q); return;
end
v = sort(v); k = max(1, min(numel(v), round((q/100)*numel(v))));
p = v(k);
end
