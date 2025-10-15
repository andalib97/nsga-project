function HRES_energy_mix_years(design_or_x, save_outputs)
% HRES_energy_mix_years (rev D)
% Visualize energy contributions across synthetic years, with a second subplot
% showing the distribution (boxplots) of energy shares by source.
%
% Usage:
%   HRES_energy_mix_years(design)
%   HRES_energy_mix_years(x)                 % [PV,WT,AA_E,AA_P,VR_E,VR_P,DG,scheme]
%   HRES_energy_mix_years(..., true)         % also saves PNG and CSV

if nargin < 2, save_outputs = false; end
if ~exist('HRES_DATA.mat','file')
    error('Run HRES_setup and HRES_make_scenarios first.');
end
load HRES_DATA.mat
global HRES_DATA
P = HRES_DATA.params; T = HRES_DATA.tech; D = HRES_DATA.diesel; S = HRES_DATA.scenarios;

% ------------- Normalize input to design struct -------------
design = local_as_design(design_or_x);

NY = S.n_years; H = S.hours_year;
E_REdir = zeros(NY,1); E_VR = zeros(NY,1); E_AA = zeros(NY,1); E_DG = zeros(NY,1); E_LOAD = zeros(NY,1);
has_stress = isfield(S,'meta') && isfield(S.meta,'is_stress_year') && numel(S.meta.is_stress_year)==NY;
stress = false(NY,1); if has_stress, stress = logical(S.meta.is_stress_year(:)); end

for y = 1:NY
    idx = (y-1)*H + (1:H);
    sc = struct('GHI',S.GHI(idx),'WS',S.WS(idx),'LOAD',S.LOAD(idx));
    sim = simulate_hres(design, P, T, D, sc, struct('metrics_energy',true));

    % Robust pulls (guard if any field is missing)
    e = sim.energy;
    E_REdir(y) = getf(e,'E_RE_direct',0);
    E_VR(y)    = getf(e,'E_vr_dis',0);
    E_AA(y)    = getf(e,'E_aa_dis',0);
    E_DG(y)    = getf(e,'E_diesel',getf(sim,'E_diesel_kWh',0));
    E_LOAD(y)  = getf(e,'E_load',sum(sc.LOAD)*P.dt_hours);
end

% Shares (clamped to [0,1])
share_REdir   = min(max(E_REdir ./ max(E_LOAD, eps), 0), 1);
share_VR      = min(max(E_VR    ./ max(E_LOAD, eps), 0), 1);
share_AA      = min(max(E_AA    ./ max(E_LOAD, eps), 0), 1);
share_DG      = min(max(E_DG    ./ max(E_LOAD, eps), 0), 1);
share_REtotal = min(max((E_REdir + E_VR + E_AA) ./ max(E_LOAD, eps), 0), 1);

% ------------- Plot: stacked energies (top) + share boxplots (bottom) -------------
[E_scale, unit_label] = local_energy_scale(max(E_LOAD));
E_stack = [E_REdir, E_VR, E_AA, E_DG] / E_scale;

tl = tiledlayout(2,1,'TileSpacing','compact','Padding','compact');

% Top: stacked bars by year
ax1 = nexttile(tl,1);
bar(ax1, E_stack, 'stacked'); grid(ax1,'on'); box(ax1,'on');
xlabel(ax1,'Synthetic year');
ylabel(ax1, sprintf('Energy to load (%s)', unit_label));
legend(ax1, {'RE direct','VRFB discharge','AA-CAES discharge','Diesel'}, 'Location','eastoutside');
title(ax1,'Mine energy supply mix across synthetic years');

% Optional: mark stress years
hold(ax1,'on');
if any(stress)
    yMax = max(sum(E_stack,2))*1.05 + eps;
    plot(ax1, find(stress), yMax*ones(nnz(stress),1), 'kv', 'MarkerFaceColor',[.5 .5 .5], ...
         'DisplayName','Stress year');
end

% Overlay RE share as line (right axis)
yyaxis(ax1,'right');
plot(ax1, share_REtotal, '-o', 'LineWidth', 1, 'MarkerSize', 3);
ylim(ax1,[0 1]);
ylabel(ax1,'Renewable share of load');

% Bottom: boxplots of shares
ax2 = nexttile(tl,2);
labels = {'RE direct','VRFB','AA-CAES','Diesel','RE total'};
dataCols = [share_REdir, share_VR, share_AA, share_DG, share_REtotal];

if exist('boxchart','file') == 2
    % Long format for boxchart
    vals = dataCols(:);
    grp  = categorical(repelem(labels(:), NY));
    boxchart(ax2, grp, vals);
else
    % Fallback: custom minimalist boxplot (uses pctile_fallback below)
    cla(ax2); hold(ax2,'on');
    local_boxplot_fallback(ax2, dataCols, labels);
end
grid(ax2,'on'); box(ax2,'on');
ylabel(ax2,'Annual energy share of load');
ylim(ax2, [0 1]);
title(ax2,'Distribution of energy shares across years');

% Optional target line for diesel-share (from setup)
if isfield(P,'diesel_share_target') && ~isempty(P.diesel_share_target)
    yline(ax2, P.diesel_share_target, '--', 'Diesel share target', ...
          'LabelHorizontalAlignment','left','Alpha',0.6);
end

% ------------- Summary stats -------------
mu_diesel = mean(E_DG);
p10 = pctile_fallback(E_DG,10);
p90 = pctile_fallback(E_DG,90);
mu_share  = mean(share_REtotal,'omitnan');
fprintf('[Energy mix] Avg diesel = %.0f kWh/yr (P10=%.0f, P90=%.0f), Avg RE share = %.1f%%\n', ...
        mu_diesel, p10, p90, 100*mu_share);

% ------------- Save outputs (optional) -------------
if save_outputs
    ts = datestr(now,'yyyymmdd_HHMMSS');
    png = sprintf('energy_mix_years_%s.png', ts);
    csv = sprintf('energy_mix_years_%s.csv', ts);
    try, exportgraphics(tl, png, 'Resolution', 180); catch, saveas(gcf, png); end
    Ttbl = table((1:NY)', E_REdir, E_VR, E_AA, E_DG, E_LOAD, ...
                 share_REdir, share_VR, share_AA, share_DG, share_REtotal, ...
        'VariableNames', {'Year','E_RE_direct_kWh','E_VR_dis_kWh','E_AA_dis_kWh','E_Diesel_kWh','E_Load_kWh', ...
                          'share_RE_direct','share_VR','share_AA','share_Diesel','share_RE_total'});
    writetable(Ttbl, csv);
    fprintf('Saved: %s, %s\n', png, csv);
end
end

% ------------------------ helpers ------------------------
function design = local_as_design(x)
if isstruct(x)
    design = x;
    need = {'PV_kW','WT_kW','AA_E','AA_P','VR_E','VR_P','DG_P','scheme'};
    missing = need(~isfield(design, need));
    if ~isempty(missing), error('Design missing fields: %s', strjoin(missing,', ')); end
    design.scheme = max(1, min(3, round(design.scheme)));
else
    if numel(x) < 8, error('Decision vector x must have 8 elements.'); end
    design = struct('PV_kW',x(1),'WT_kW',x(2), ...
                    'AA_E',x(3),'AA_P',x(4), ...
                    'VR_E',x(5),'VR_P',x(6), ...
                    'DG_P',x(7),'scheme',max(1,min(3,round(x(8)))));
end
end

function v = getf(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
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

function [scale, unit] = local_energy_scale(maxE_kWh)
if maxE_kWh >= 1e9
    scale = 1e6; unit = 'GWh';
elseif maxE_kWh >= 1e6
    scale = 1e3; unit = 'MWh';
else
    scale = 1;   unit = 'kWh';
end
end

function local_boxplot_fallback(ax, dataCols, labels)
% Minimalist boxplot without toolboxes: draws median, IQR box, whiskers.
n = size(dataCols,2);
xpos = 1:n; w = 0.6;
for i = 1:n
    v = dataCols(:,i); v = v(isfinite(v));
    if isempty(v), continue; end
    q1 = pctile_fallback(v,25);
    q2 = pctile_fallback(v,50);
    q3 = pctile_fallback(v,75);
    iqr = q3-q1;
    lo = max(min(v(v>=q1-1.5*iqr)), min(v)); if isempty(lo), lo=min(v); end
    hi = min(max(v(v<=q3+1.5*iqr)), max(v)); if isempty(hi), hi=max(v); end

    % box
    patch(ax, [xpos(i)-w/2 xpos(i)+w/2 xpos(i)+w/2 xpos(i)-w/2], [q1 q1 q3 q3], ...
          0.9*[1 1 1], 'EdgeColor',[0 0 0]);
    % whiskers
    plot(ax, [xpos(i) xpos(i)], [lo q1], '-k');
    plot(ax, [xpos(i) xpos(i)], [q3 hi], '-k');
    % caps
    plot(ax, [xpos(i)-w/4 xpos(i)+w/4], [lo lo], '-k');
    plot(ax, [xpos(i)-w/4 xpos(i)+w/4], [hi hi], '-k');
    % median
    plot(ax, [xpos(i)-w/2 xpos(i)+w/2], [q2 q2], '-k','LineWidth',1.5);
end
xlim(ax, [0.5 n+0.5]);
set(ax,'XTick',xpos,'XTickLabel',labels,'XTickLabelRotation',0);
end
