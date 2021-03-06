% EXACT_INFERENCE infExact replacement supporting Hessian calculation.
%
% This provides a GPML-compatible inference method performing exact
% inference with a Gaussian likelihood that supports an extended API
% allowing the calculation of the Hessian of the negative log
% likelihood at \theta. This can be used as a drop-in replacement for
% infExact with no extra computational cost.
%
% See infMethods.m for help on GPML inference methods in general.
% The Hessian of -\log p(y | X, \theta) may be calculated as the
% fourth output of
%
%   [posterior, nlZ, dnlZ, HnlZ] = ...
%       exact_inference(hyperparameters, mean_function, ...
%                       covariance_function, likelihood, x, y);
%
% See hessians.m for information regarding the Hessian struct HnlZ.
%
% To use this functionality, both the mean and covariance functions
% must support an extended GPML syntax that for calculating the
% Hessian of the training mean mu or training covariance K with respect
% to any pair of hyperparameters.  The syntax for mean functions
% is:
%
%   dmu_didj = mean_function(hyperparameters, x, i, j);
%
% where dmu_didj is \partial^2 mu(x) / \partial \theta_i \partial \theta_j.
%
% The syntax for covariance functions is similar:
%
%   dK2_didj = covariance_function(hyperparameters, x, [], i, j);
%
% where dK2_didj is \partial^2 K(x, x) / \partial \theta_i \partial \theta_j.
%
% See also INFMETHODS, HESSIANS.

% Copyright (c) 2013--2014 Roman Garnett.

function [posterior, nlZ, dnlZ, HnlZ] = exact_inference(hyperparameters, ...
          mean_function, covariance_function, ~, x, y)

  % If Hessian is not requested, simply call infExact and
  % return. This allows us to assume the Hessian is needed for the
  % remainder of the code, making it more readible.

  if (nargout <= 1)
    posterior = ...
        infExact(hyperparameters, mean_function, covariance_function, ...
                 'likGauss', x, y);
    return;
  elseif (nargout == 2)
    [posterior, nlZ] = ...
        infExact(hyperparameters, mean_function, covariance_function, ...
                 'likGauss', x, y);
    return;
  elseif (nargout == 3)
    [posterior, nlZ, dnlZ] = ...
        infExact(hyperparameters, mean_function, covariance_function, ...
                 'likGauss', x, y);
    return;
  end

  % skipping error checks on likelihood, assuming likGauss no
  % matter what the user says

  n = size(x, 1);
  I = eye(n);

  % initialize gradient and Hessian
  dnlZ = hyperparameters;

  num_cov  = numel(hyperparameters.cov);
  num_mean = numel(hyperparameters.mean);
  num_hyperparameters = 1 + num_cov + num_mean;

  HnlZ.H              = zeros(num_hyperparameters);
  HnlZ.covariance_ind = 1:num_cov;
  HnlZ.likelihood_ind = (num_cov + 1);
  HnlZ.mean_ind       = (num_cov + 2):num_hyperparameters;

  % convenience handles
  mu = @(varargin) feval(mean_function{:},       hyperparameters.mean, varargin{:});
  K  = @(varargin) feval(covariance_function{:}, hyperparameters.cov,  varargin{:});

  % computes tr(AB) for symmetric A, B
  product_trace = @(A, B) (A(:)' * B(:));

  noise_variance = exp(2 * hyperparameters.lik);
  high_noise = (noise_variance >= 1e-6);

  % compute posterior if needed
  if (isstruct(y))
    % in case a posterior is provided, we need to calculate:
    %
    % - (y - mu(x))
    % - L = chol(K + sigma^2 I)

    posterior = y;
    alpha = posterior.alpha;

    % derive y from posterior.alpha
    V = K(x) + diag(noise_variance + zeros(n, 1));
    y = V * posterior.alpha;

    if (is_chol(posterior.L))
      % high-noise parameterization: posterior.L contains chol(K / sigma^2 + I)

      factor = (1 / noise_variance);
      L = posterior.L;
    else
      % low-noise parameterization: posterior.L contains -inv(K + \sigma^2 I)
      % in this case it's fastest to recompute L

      factor = 1;
      L = chol(V);
    end

    V_inv_times = @(x) solve_chol(L, x) * factor;

  else
    % handle small noise specially to avoid numerical problems (GPML 3.4)
    if (high_noise)
      % high-noise parameterization: posterior.L contains chol(K / sigma^2 + I)

      factor = (1 / noise_variance);
      L = chol(K(x) * factor + I);
      posterior.L = L;
    else
      % low-noise parameterization: posterior.L contains -inv(K + \sigma^2 I)

      factor = 1;
      L = chol(K(x) + diag(noise_variance + zeros(n, 1)));
      posterior.L = -solve_chol(L, I);
    end

    V_inv_times = @(x) solve_chol(L, x) * factor;

    y = y - mu(x);
    alpha = V_inv_times(y);

    posterior.alpha = alpha;
    posterior.sW    = ones(n, 1) * (1 / sqrt(noise_variance));
  end

  % negative log likelihood
  nlZ = sum(log(diag(L))) + ...
        0.5 * (y' * alpha + n * log(2 * pi / factor));

  % calculate (K + \sigma^2 I)^{-1} if needed
  if (is_chol(posterior.L))
    V_inv = V_inv_times(I);
  else
    % desired inverse already calculated in low-noise case
    V_inv = -posterior.L;
  end

  % precompute (K + \sigma^2 I)^{-1}\alpha; it's used a lot
  V_inv_alpha = V_inv_times(alpha);

  % derivative with respect to log noise scale
  dnlZ.lik = noise_variance * (trace(V_inv) - alpha' * alpha);

  % second derivative with respect to log noise scale
  HnlZ.H(HnlZ.likelihood_ind, HnlZ.likelihood_ind) = ...
      2 * noise_variance^2 * ...
      (2 * alpha' * V_inv_alpha - product_trace(V_inv, V_inv)) + ...
      2 * dnlZ.lik;

  % store derivatives of m with respect to mean hyperparameters for reuse
  dm = zeros(n, num_mean);

  % handle gradient/Hessian entries with respect to mean hyperparameters
  for i = 1:num_mean
    dm(:, i) = mu(x, i);

    % gradient with respect to this mean parameter
    dnlZ.mean(i) = -dm(:, i)' * alpha;

    % mean/mean Hessian entries
    for j = 1:i
      d2m_didj = mu(x, i, j);

      HnlZ.H(HnlZ.mean_ind(i), HnlZ.mean_ind(j)) = ...
          dm(:, i)' * V_inv_times(dm(:, j)) + ...
          d2m_didj' * alpha;
    end

    % mean/noise Hessian entry
    HnlZ.H(HnlZ.mean_ind(i), HnlZ.likelihood_ind) = ...
        2 * noise_variance * dm(:, i)' * V_inv_alpha;
  end

  % compute and store V^{-1} K'_i for Hessian computations
  V_inv_dK = zeros(n, n, num_cov);

  % handle gradient/Hessian entries with respect tocovariance
  % hyperparameters
  for i = 1:num_cov
    dK = K(x, [], i);

    V_inv_dK(:, :, i) = V_inv_times(dK);

    % gradient with respect to this covariance parameter
    dnlZ.cov(i) = 0.5 * (trace(V_inv_dK(:, :, i)) - alpha' * dK * alpha);

    % covariance/covariance Hessian entries
    for j = 1:i
      HK = K(x, [], i, j);

      HnlZ.H(HnlZ.covariance_ind(i), HnlZ.covariance_ind(j)) = ...
          y' * V_inv_dK(:, :, i) * V_inv_dK(:, :, j) * alpha + ...
          0.5 * (product_trace(V_inv, HK) - ...
                 product_trace(V_inv_dK(:, :, i), V_inv_dK(:, :, j)') - ...
                 alpha' * HK * alpha);
    end

    % covariance/mean Hessian entries
    for j = 1:num_mean
      HnlZ.H(HnlZ.mean_ind(j), HnlZ.covariance_ind(i)) = ...
          dm(:, j)' * V_inv_dK(:, :, i) * alpha;
    end

    % covariance/noise Hessian entry
    HnlZ.H(HnlZ.likelihood_ind, HnlZ.covariance_ind(i)) = ...
        noise_variance * (2 * y' * V_inv_dK(:, :, i) * V_inv_alpha -...
                          product_trace(V_inv_dK(:, :, i), V_inv));
  end

  % symmetrize Hessian
  HnlZ.H = HnlZ.H + tril(HnlZ.H, -1)';

end