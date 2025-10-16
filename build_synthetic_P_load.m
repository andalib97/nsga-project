function P_load = build_synthetic_P_load(cfg)
% build_synthetic_P_load  Create a realistic hourly mine load series (kW).
%
% Optional cfg fields (all have defaults):
%   base_MW (8), year_hours (8760), diurnal_pct (5), weekly_pct (2),
%   seasonal_pct (3), noise_pct (1.5), shift_hours ([6 18]),
%   shift_pct (2), shift_sigma_h (1), peak_cap_kW ([]), save_mat (true),
%   seed (5931)
%
% Output:
%   P_load  [H x 1] hourly demand in kW

    if nargin < 1 || ~isstruct(cfg), cfg = struct; end

    % --- safe getter (never references a missing field) ---
    get = @(name,def) local_get(cfg,name,def);

    base_MW     = get('base_MW',8);
    H           = get('year_hours',8760);
    diurnal_pp  = get('diurnal_pct',5)/100;
    weekly_pp   = get('weekly_pct',2)/100;
    seasonal_pp = get('seasonal_pct',3)/100;
    noise_pct   = get('noise_pct',1.5)/100;
    shift_hours = get('shift_hours',[6 18]);
    shift_pct   = get('shift_pct',2)/100;
    shift_sigma = get('shift_sigma_h',1);
    cap_kW      = get('peak_cap_kW',[]);
    do_save     = get('save_mat',true);
    seed        = get('seed',5931);

    rng(seed);

    t   = (0:H-1)';                   % hours since start
    hod = mod(t,24);                  % hour-of-day 0..23
    dow = mod(floor(t/24),7);         % day-of-week 0..6
    hyo = t;                          % hour-of-year

    base_kW = base_MW*1000 * ones(H,1);

    % Diurnal (tiny swing, peak late afternoon)
    A_day   = diurnal_pp/2;  phi_day = -6; % hours
    diurnal = 1 + A_day * sin(2*pi*(hod - phi_day)/24);

    % Weekly (tiny; Sunday lower)
    A_week  = weekly_pp/2;
    weekly  = 1 + A_week * sin(2*pi*(dow)/7 - pi/2);

    % Seasonal (tiny)
    A_seas  = seasonal_pp/2;
    seasonal= 1 + A_seas * sin(2*pi*hyo/H - pi/2);

    % Shift-change pulses (Gaussian bumps)
    pulses = zeros(H,1);
    for k = 1:numel(shift_hours)
        mu = shift_hours(k);
        d = min(mod(hod-mu,24), mod(mu-hod,24));     % circular distance
        pulses = pulses + shift_pct * exp(-0.5*(d/shift_sigma).^2);
    end
    shift_factor = 1 + pulses;

    % Small noise
    noise = 1 + noise_pct * randn(H,1);

    % Combine multiplicatively
    P_load = base_kW .* diurnal .* weekly .* seasonal .* shift_factor .* noise;

    % Clip and cap
    P_load = max(P_load, 0);
    if ~isempty(cap_kW), P_load = min(P_load, cap_kW); end
    P_load = P_load(:);

    if do_save
        save('P_load.mat','P_load');
        fprintf('Saved P_load.mat (%d hours). Mean = %.1f kW, Peak = %.1f kW\n', ...
            H, mean(P_load), max(P_load));
    end
end

function v = local_get(s, field, def)
    if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
        v = s.(field);
    else
        v = def;
    end
end
