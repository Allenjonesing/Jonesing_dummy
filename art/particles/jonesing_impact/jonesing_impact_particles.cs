// jonesing_impact_particles.cs
// Impact particle datablocks for the Jonesing dummy mod.
//
// KEY INSIGHT — why "changing diffuse color" doesn't work:
//   In Torque3D-style particle systems (which BeamNG uses), the visible colour
//   of a particle is determined by the particle's own colorOverLife keyframes
//   (colors[0..3] / colorKeytimes[0..3]), NOT by the material's diffuseColor
//   property.  diffuseColor is just a tint multiplied on top; if the particle
//   colour keyframes are already very saturated (e.g. full red) the tint has
//   no visible effect.  Recolouring must happen here, in the ParticleData.
//
// RECOLOUR PATTERN:
//   Each preset has a default ParticleData and two named colour variants (_Red,
//   _Blue) defined as derived datablocks that override only the colors[] fields.
//   Matching *_Emitter datablocks swap in the coloured particles.
//   The Lua spawn library reads presetName + optional colourVariant and selects
//   the correct emitter name automatically.
//
// DO NOT edit core BeamNG particle files — all definitions live here in the mod.

//=============================================================================
// PRESET 1: impact_sparks
//   Yellow-white sparks with gravity/drag, cone-shaped burst.
//=============================================================================

datablock ParticleData(jonesing_Sparks_Particle)
{
   textureName          = "art/particles/spark";
   dragCoefficient      = 1.5;
   gravityCoefficient   = 0.6;
   windCoefficient      = 0.0;
   lifetimeMS           = 700;
   lifetimeVarianceMS   = 150;
   spinSpeed            = 0.0;
   spinRandomMin        = 0.0;
   spinRandomMax        = 0.0;
   useInvAlpha          = false;

   // colorOverLife: yellow-white → orange → charcoal (fade out).
   // These KEYFRAMES are the only reliable colour control in Torque particles.
   colors[0]            = "1.0 0.95 0.4 1.0";
   colors[1]            = "1.0 0.50 0.1 0.8";
   colors[2]            = "0.3 0.20 0.1 0.3";
   colors[3]            = "0.1 0.05 0.0 0.0";
   colorKeytimes[0]     = 0.0;
   colorKeytimes[1]     = 0.3;
   colorKeytimes[2]     = 0.7;
   colorKeytimes[3]     = 1.0;

   sizes[0]             = 0.04;
   sizes[1]             = 0.06;
   sizes[2]             = 0.03;
   sizes[3]             = 0.00;
   sizeKeytimes[0]      = 0.0;
   sizeKeytimes[1]      = 0.2;
   sizeKeytimes[2]      = 0.7;
   sizeKeytimes[3]      = 1.0;
};

// Red variant — crimson sparks (e.g. incendiary / heated metal).
datablock ParticleData(jonesing_Sparks_Red_Particle : jonesing_Sparks_Particle)
{
   colors[0]            = "1.0 0.10 0.00 1.0";
   colors[1]            = "0.9 0.00 0.00 0.8";
   colors[2]            = "0.4 0.00 0.00 0.3";
   colors[3]            = "0.1 0.00 0.00 0.0";
};

// Blue variant — electric / plasma sparks.
datablock ParticleData(jonesing_Sparks_Blue_Particle : jonesing_Sparks_Particle)
{
   colors[0]            = "0.30 0.50 1.00 1.0";
   colors[1]            = "0.10 0.25 0.90 0.8";
   colors[2]            = "0.00 0.10 0.40 0.3";
   colors[3]            = "0.00 0.00 0.10 0.0";
};

datablock ParticleEmitterData(jonesing_ImpactSparks_Emitter)
{
   ejectionPeriodMS     = 8;
   periodVarianceMS     = 2;
   ejectionVelocity     = 4.0;
   velocityVariance     = 1.5;
   ejectionOffset       = 0.0;
   thetaMin             = 0;
   thetaMax             = 60;
   phiReferenceVel      = 0;
   phiVariance          = 360;
   overrideAdvance      = false;
   particles            = "jonesing_Sparks_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactSparks_Red_Emitter : jonesing_ImpactSparks_Emitter)
{
   particles            = "jonesing_Sparks_Red_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactSparks_Blue_Emitter : jonesing_ImpactSparks_Emitter)
{
   particles            = "jonesing_Sparks_Blue_Particle";
};

//=============================================================================
// PRESET 2: impact_dust_puff
//   Expanding brownish dust cloud that quickly fades.
//=============================================================================

datablock ParticleData(jonesing_Dust_Particle)
{
   textureName          = "art/particles/smoke";
   dragCoefficient      = 0.4;
   gravityCoefficient   = -0.05;  // slight upward drift
   windCoefficient      = 0.0;
   lifetimeMS           = 1200;
   lifetimeVarianceMS   = 200;
   spinSpeed            = 0.3;
   spinRandomMin        = -45.0;
   spinRandomMax        =  45.0;
   useInvAlpha          = true;

   colors[0]            = "0.70 0.65 0.55 0.80";
   colors[1]            = "0.60 0.55 0.45 0.50";
   colors[2]            = "0.50 0.45 0.35 0.20";
   colors[3]            = "0.40 0.35 0.25 0.00";
   colorKeytimes[0]     = 0.0;
   colorKeytimes[1]     = 0.3;
   colorKeytimes[2]     = 0.7;
   colorKeytimes[3]     = 1.0;

   sizes[0]             = 0.10;
   sizes[1]             = 0.40;
   sizes[2]             = 0.70;
   sizes[3]             = 0.90;
   sizeKeytimes[0]      = 0.0;
   sizeKeytimes[1]      = 0.2;
   sizeKeytimes[2]      = 0.6;
   sizeKeytimes[3]      = 1.0;
};

datablock ParticleData(jonesing_Dust_Red_Particle : jonesing_Dust_Particle)
{
   colors[0]            = "0.80 0.20 0.20 0.80";
   colors[1]            = "0.60 0.10 0.10 0.50";
   colors[2]            = "0.30 0.05 0.05 0.20";
   colors[3]            = "0.10 0.00 0.00 0.00";
};

datablock ParticleData(jonesing_Dust_Blue_Particle : jonesing_Dust_Particle)
{
   colors[0]            = "0.20 0.30 0.80 0.80";
   colors[1]            = "0.10 0.20 0.60 0.50";
   colors[2]            = "0.00 0.10 0.30 0.20";
   colors[3]            = "0.00 0.00 0.10 0.00";
};

datablock ParticleEmitterData(jonesing_ImpactDust_Emitter)
{
   ejectionPeriodMS     = 20;
   periodVarianceMS     = 5;
   ejectionVelocity     = 1.5;
   velocityVariance     = 0.5;
   ejectionOffset       = 0.0;
   thetaMin             = 0;
   thetaMax             = 90;
   phiReferenceVel      = 0;
   phiVariance          = 360;
   overrideAdvance      = false;
   particles            = "jonesing_Dust_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactDust_Red_Emitter : jonesing_ImpactDust_Emitter)
{
   particles            = "jonesing_Dust_Red_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactDust_Blue_Emitter : jonesing_ImpactDust_Emitter)
{
   particles            = "jonesing_Dust_Blue_Particle";
};

//=============================================================================
// PRESET 3: impact_blood_spray
//   Dark red droplets sprayed in a cone (dummy ground/vehicle impact).
//=============================================================================

datablock ParticleData(jonesing_Blood_Particle)
{
   textureName          = "art/particles/droplets";
   dragCoefficient      = 0.8;
   gravityCoefficient   = 1.2;
   windCoefficient      = 0.0;
   lifetimeMS           = 600;
   lifetimeVarianceMS   = 100;
   spinSpeed            = 0.0;
   spinRandomMin        = 0.0;
   spinRandomMax        = 0.0;
   useInvAlpha          = false;

   colors[0]            = "0.70 0.00 0.00 1.00";
   colors[1]            = "0.55 0.00 0.00 0.80";
   colors[2]            = "0.30 0.00 0.00 0.40";
   colors[3]            = "0.10 0.00 0.00 0.00";
   colorKeytimes[0]     = 0.0;
   colorKeytimes[1]     = 0.3;
   colorKeytimes[2]     = 0.7;
   colorKeytimes[3]     = 1.0;

   sizes[0]             = 0.03;
   sizes[1]             = 0.05;
   sizes[2]             = 0.04;
   sizes[3]             = 0.00;
   sizeKeytimes[0]      = 0.0;
   sizeKeytimes[1]      = 0.2;
   sizeKeytimes[2]      = 0.8;
   sizeKeytimes[3]      = 1.0;
};

// Red variant — brighter arterial red.
datablock ParticleData(jonesing_Blood_Red_Particle : jonesing_Blood_Particle)
{
   colors[0]            = "0.90 0.05 0.00 1.00";
   colors[1]            = "0.70 0.00 0.00 0.80";
   colors[2]            = "0.40 0.00 0.00 0.40";
   colors[3]            = "0.10 0.00 0.00 0.00";
};

// Blue variant — alien/ichor blood.
datablock ParticleData(jonesing_Blood_Blue_Particle : jonesing_Blood_Particle)
{
   colors[0]            = "0.00 0.10 0.90 1.00";
   colors[1]            = "0.00 0.10 0.65 0.80";
   colors[2]            = "0.00 0.05 0.30 0.40";
   colors[3]            = "0.00 0.00 0.10 0.00";
};

datablock ParticleEmitterData(jonesing_ImpactBlood_Emitter)
{
   ejectionPeriodMS     = 6;
   periodVarianceMS     = 2;
   ejectionVelocity     = 3.5;
   velocityVariance     = 1.2;
   ejectionOffset       = 0.0;
   thetaMin             = 0;
   thetaMax             = 70;
   phiReferenceVel      = 0;
   phiVariance          = 360;
   overrideAdvance      = false;
   particles            = "jonesing_Blood_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactBlood_Red_Emitter : jonesing_ImpactBlood_Emitter)
{
   particles            = "jonesing_Blood_Red_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactBlood_Blue_Emitter : jonesing_ImpactBlood_Emitter)
{
   particles            = "jonesing_Blood_Blue_Particle";
};

//=============================================================================
// PRESET 4: impact_gibs_light
//   Small reddish flecks / chunky debris — "light gibs".
//=============================================================================

datablock ParticleData(jonesing_Gibs_Particle)
{
   textureName          = "art/particles/chunk";
   dragCoefficient      = 0.6;
   gravityCoefficient   = 1.5;
   windCoefficient      = 0.0;
   lifetimeMS           = 900;
   lifetimeVarianceMS   = 200;
   spinSpeed            = 2.0;
   spinRandomMin        = -90.0;
   spinRandomMax        =  90.0;
   useInvAlpha          = false;

   colors[0]            = "0.80 0.05 0.05 1.00";
   colors[1]            = "0.60 0.03 0.03 0.80";
   colors[2]            = "0.30 0.02 0.02 0.50";
   colors[3]            = "0.10 0.00 0.00 0.00";
   colorKeytimes[0]     = 0.0;
   colorKeytimes[1]     = 0.3;
   colorKeytimes[2]     = 0.7;
   colorKeytimes[3]     = 1.0;

   sizes[0]             = 0.05;
   sizes[1]             = 0.08;
   sizes[2]             = 0.06;
   sizes[3]             = 0.02;
   sizeKeytimes[0]      = 0.0;
   sizeKeytimes[1]      = 0.1;
   sizeKeytimes[2]      = 0.6;
   sizeKeytimes[3]      = 1.0;
};

datablock ParticleData(jonesing_Gibs_Red_Particle : jonesing_Gibs_Particle)
{
   colors[0]            = "1.00 0.00 0.00 1.00";
   colors[1]            = "0.75 0.00 0.00 0.80";
   colors[2]            = "0.40 0.00 0.00 0.50";
   colors[3]            = "0.10 0.00 0.00 0.00";
};

datablock ParticleData(jonesing_Gibs_Blue_Particle : jonesing_Gibs_Particle)
{
   colors[0]            = "0.00 0.10 1.00 1.00";
   colors[1]            = "0.00 0.10 0.75 0.80";
   colors[2]            = "0.00 0.05 0.35 0.50";
   colors[3]            = "0.00 0.00 0.10 0.00";
};

datablock ParticleEmitterData(jonesing_ImpactGibs_Emitter)
{
   ejectionPeriodMS     = 15;
   periodVarianceMS     = 5;
   ejectionVelocity     = 5.0;
   velocityVariance     = 2.0;
   ejectionOffset       = 0.0;
   thetaMin             = 0;
   thetaMax             = 80;
   phiReferenceVel      = 0;
   phiVariance          = 360;
   overrideAdvance      = false;
   particles            = "jonesing_Gibs_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactGibs_Red_Emitter : jonesing_ImpactGibs_Emitter)
{
   particles            = "jonesing_Gibs_Red_Particle";
};

datablock ParticleEmitterData(jonesing_ImpactGibs_Blue_Emitter : jonesing_ImpactGibs_Emitter)
{
   particles            = "jonesing_Gibs_Blue_Particle";
};
